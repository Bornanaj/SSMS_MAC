import Foundation
import TDSKit

/// What a data deployment will do, and the script that does it.
public struct DataSyncPlan: Sendable {
    public struct TableCounts: Sendable, Identifiable {
        public var id: String
        public var table: String
        public var inserts: Int
        public var updates: Int
        public var deletes: Int
    }

    public var script: String
    public var tables: [TableCounts]
    public var warnings: [DeploymentWarning]

    public var totalInserts: Int { tables.reduce(0) { $0 + $1.inserts } }
    public var totalUpdates: Int { tables.reduce(0) { $0 + $1.updates } }
    public var totalDeletes: Int { tables.reduce(0) { $0 + $1.deletes } }
    public var isEmpty: Bool { totalInserts + totalUpdates + totalDeletes == 0 }
}

/// Writes the INSERT / UPDATE / DELETE script that makes the target's rows match the
/// source's, for the tables and rows that are selected.
///
/// Foreign keys and triggers that are enabled are switched off around the changes and back on
/// afterwards (foreign keys re-checked, so the result is still trusted); without that option
/// deletes run child-first and inserts parent-first along the foreign keys.
public struct DataSyncScripter: Sendable {
    public let comparison: DataComparison
    public var options: DataCompareOptions

    public init(comparison: DataComparison, options: DataCompareOptions? = nil) {
        self.comparison = comparison
        self.options = options ?? comparison.options
    }

    public func plan() -> DataSyncPlan {
        var warnings: [DeploymentWarning] = []
        let tables = comparison.tables.filter { $0.isSelected && $0.error == nil && $0.hasDifferences }
        for table in comparison.tables where table.isSelected && table.isTruncated {
            warnings.append(DeploymentWarning(severity: .high, object: table.mapping.target.qualifiedName,
                                              message: "Not every difference was kept, so the script covers only the "
                                              + "first \(options.maximumRowsKept) rows of each kind. Raise the limit "
                                              + "and compare again to synchronize the rest."))
        }

        // Work out statements per table first; order and wrap them afterwards.
        var work: [TableWork] = []
        for table in tables {
            let item = statements(for: table, warnings: &warnings)
            if item.deletes.isEmpty && item.updates.isEmpty && item.inserts.isEmpty && item.reseed == nil { continue }
            work.append(item)
        }

        let affected = Set(work.map(\.id))
        let order = dependencyOrder(affected)
        let parentsFirst = work.sorted { (order[$0.id] ?? 0, $0.id) < (order[$1.id] ?? 0, $1.id) }
        let childrenFirst = Array(parentsFirst.reversed())

        var out = header()
        let go = "GO\n"
        let check = "IF @@ERROR <> 0 SET NOEXEC ON\n" + go
        let transactional = !options.doNotUseTransactions
        out += "SET NUMERIC_ROUNDABORT OFF\n" + go
        out += "SET ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL, ARITHABORT, QUOTED_IDENTIFIER, "
            + "ANSI_NULLS ON\n" + go
        if options.addDatabaseUseStatement {
            out += "USE \(SQLIdentifier.quote(comparison.targetDatabase))\n" + go
        }
        if transactional {
            out += "SET XACT_ABORT ON\n" + go
            out += "BEGIN TRANSACTION\n" + go
        }

        func emit(_ comment: String, _ batches: [String]) {
            guard !batches.isEmpty else { return }
            if options.includeComments { out += "PRINT \(SQLIdentifier.literal(comment))\n" + go }
            for batch in batches {
                out += batch + "\n" + go
                if transactional { out += check }
            }
        }

        // Foreign keys: every enabled key on an affected table or pointing at one.
        let foreignKeys = comparison.targetForeignKeys.filter { key in
            key.isEnabled && (affected.contains(key.table) || affected.contains(key.referencedTable))
        }
        if options.disableForeignKeys, !foreignKeys.isEmpty {
            emit("Disabling foreign keys", foreignKeys.map { key in
                "ALTER TABLE \(key.quotedTable) NOCHECK CONSTRAINT \(SQLIdentifier.quote(key.name))"
            })
        }
        if options.disableDMLTriggers {
            var batches: [String] = []
            for item in parentsFirst {
                for trigger in item.triggers {
                    batches.append("DISABLE TRIGGER \(SQLIdentifier.quote(schema: item.schema, name: trigger)) "
                                   + "ON \(item.quotedName)")
                }
            }
            emit("Disabling DML triggers", batches)
        }

        for item in childrenFirst where !item.deletes.isEmpty {
            emit("Deleting rows from \(item.quotedName)", batched(item.deletes))
        }
        for item in parentsFirst where !item.updates.isEmpty {
            emit("Updating rows in \(item.quotedName)", batched(item.updates))
        }
        for item in parentsFirst where !item.inserts.isEmpty {
            var batches = batched(item.inserts)
            if item.identityInsert {
                batches.insert("SET IDENTITY_INSERT \(item.quotedName) ON", at: 0)
                batches.append("SET IDENTITY_INSERT \(item.quotedName) OFF")
            }
            emit("Adding rows to \(item.quotedName)", batches)
        }
        let reseeds = parentsFirst.compactMap(\.reseed)
        emit("Reseeding identity columns", reseeds)

        if options.disableDMLTriggers {
            var batches: [String] = []
            for item in parentsFirst {
                for trigger in item.triggers {
                    batches.append("ENABLE TRIGGER \(SQLIdentifier.quote(schema: item.schema, name: trigger)) "
                                   + "ON \(item.quotedName)")
                }
            }
            emit("Enabling DML triggers", batches)
        }
        if options.disableForeignKeys, !foreignKeys.isEmpty {
            emit("Enabling foreign keys", foreignKeys.map { key in
                // Keys that were trusted are checked again so they stay trusted.
                "ALTER TABLE \(key.quotedTable) \(key.isTrusted ? "WITH CHECK " : "")CHECK CONSTRAINT "
                    + SQLIdentifier.quote(key.name)
            })
        }

        if transactional {
            out += "COMMIT TRANSACTION\n" + go
            out += check
            out += """
            DECLARE @Success AS BIT
            SET @Success = 1
            SET NOEXEC OFF
            IF (@Success = 1) PRINT 'The database update succeeded'
            ELSE BEGIN
                IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION
                PRINT 'The database update failed'
            END

            """ + go
        }

        let counts = work.map { item in
            DataSyncPlan.TableCounts(id: item.id, table: item.quotedName, inserts: item.insertCount,
                                     updates: item.updates.count, deletes: item.deletes.count)
        }
        return DataSyncPlan(script: out, tables: counts, warnings: warnings)
    }

    // MARK: - Per table

    private struct TableWork {
        var id: String
        var schema: String
        var quotedName: String
        var deletes: [String] = []
        var updates: [String] = []
        var inserts: [String] = []
        var insertCount = 0
        var identityInsert = false
        var reseed: String?
        var triggers: [String] = []
    }

    private func statements(for table: DataTableResult, warnings: inout [DeploymentWarning]) -> TableWork {
        let mapping = table.mapping
        var work = TableWork(id: mapping.target.id, schema: mapping.target.schema,
                             quotedName: mapping.target.quotedName)
        work.triggers = mapping.target.enabledTriggers
        let keys = mapping.keyColumns
        let compared = mapping.comparedColumns
        let keyNames = keys.map { SQLIdentifier.quote($0.targetColumn) }

        func whereClause(_ values: [TDSValue]) -> String {
            var parts: [String] = []
            for (index, name) in keyNames.enumerated() where index < values.count {
                if values[index].isNull {
                    parts.append("\(name) IS NULL")
                } else {
                    parts.append("\(name) = \(SQLLiteral.render(values[index]))")
                }
            }
            return parts.joined(separator: " AND ")
        }

        let selected = table.rows.filter(\.isSelected)
        if options.deployDeletes {
            for row in selected where row.status == .onlyInTarget {
                work.deletes.append("DELETE FROM \(work.quotedName) WHERE \(whereClause(row.key))")
            }
        }
        if options.deployUpdates {
            for row in selected where row.status == .different {
                guard let source = row.source else { continue }
                var assignments: [String] = []
                for index in row.differingColumns where index < compared.count && index < source.count {
                    let column = compared[index]
                    if column.target.isReadOnly { continue }
                    assignments.append("\(SQLIdentifier.quote(column.targetColumn)) = \(SQLLiteral.render(source[index]))")
                }
                guard !assignments.isEmpty else { continue }
                work.updates.append("UPDATE \(work.quotedName) SET " + assignments.joined(separator: ", ")
                                    + " WHERE \(whereClause(row.key))")
            }
        }
        if options.deployInserts {
            // Every writable column that was read; key columns always.
            var positions: [(name: String, source: Int, isKey: Bool)] = []
            for (index, column) in keys.enumerated() where !column.target.isReadOnly {
                positions.append((column.targetColumn, index, true))
            }
            for (index, column) in compared.enumerated() where !column.target.isReadOnly {
                positions.append((column.targetColumn, index, false))
            }
            let rows = selected.filter { $0.status == .onlyInSource }
            if !rows.isEmpty {
                let identityColumn = mapping.target.columns.first(where: \.isIdentity)
                if let identityColumn,
                   positions.contains(where: { $0.name.caseInsensitiveCompare(identityColumn.name) == .orderedSame }) {
                    work.identityInsert = true
                }
                let skipped = mapping.target.columns.filter { column in
                    !column.isReadOnly && !column.isNullable
                        && !positions.contains(where: { $0.name.caseInsensitiveCompare(column.name) == .orderedSame })
                        && !(column.isIdentity && !work.identityInsert)
                }
                if !skipped.isEmpty {
                    warnings.append(DeploymentWarning(
                        severity: .medium, object: mapping.target.qualifiedName,
                        message: "Inserted rows get no value for NOT NULL column(s) "
                        + skipped.map { SQLIdentifier.quote($0.name) }.joined(separator: ", ")
                        + " because they are not compared; the insert relies on their defaults."))
                }
                let columnList = positions.map { SQLIdentifier.quote($0.name) }.joined(separator: ", ")
                let chunkSize = 100
                var index = 0
                while index < rows.count {
                    let chunk = rows[index..<min(index + chunkSize, rows.count)]
                    let values = chunk.map { row -> String in
                        let items = positions.map { position -> String in
                            let value: TDSValue
                            if position.isKey {
                                value = position.source < row.key.count ? row.key[position.source] : .null
                            } else {
                                value = row.source.map { position.source < $0.count ? $0[position.source] : .null } ?? .null
                            }
                            return SQLLiteral.render(value)
                        }
                        return "(" + items.joined(separator: ", ") + ")"
                    }
                    work.inserts.append("INSERT INTO \(work.quotedName) (\(columnList)) VALUES\n"
                                        + values.joined(separator: ",\n"))
                    index += chunkSize
                }
                work.insertCount = rows.count
            }
        }
        if options.reseedIdentityColumns, let identity = table.sourceIdentity, !identity.isNull {
            work.reseed = "DBCC CHECKIDENT(\(SQLIdentifier.literal(work.quotedName)), RESEED, \(identity.displayString()))"
        }
        return work
    }

    /// Groups statements so each GO batch holds about `rowsPerBatch` of them.
    private func batched(_ statements: [String]) -> [String] {
        let size = max(1, options.rowsPerBatch)
        var batches: [String] = []
        var index = 0
        while index < statements.count {
            batches.append(statements[index..<min(index + size, statements.count)].joined(separator: "\n"))
            index += size
        }
        return batches
    }

    /// Depth of each affected table in the foreign key graph: parents get lower numbers.
    private func dependencyOrder(_ tables: Set<String>) -> [String: Int] {
        var parents: [String: Set<String>] = [:]
        for key in comparison.targetForeignKeys where tables.contains(key.table) && tables.contains(key.referencedTable)
            && key.table != key.referencedTable {
            parents[key.table, default: []].insert(key.referencedTable)
        }
        var depth: [String: Int] = [:]
        func visit(_ table: String, _ path: Set<String>) -> Int {
            if let known = depth[table] { return known }
            guard !path.contains(table) else { return 0 }
            let value = (parents[table] ?? []).map { visit($0, path.union([table])) + 1 }.max() ?? 0
            depth[table] = value
            return value
        }
        for table in tables { _ = visit(table, []) }
        return depth
    }

    private func header() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return """
        /*
            Data synchronization script generated by SSMS for Mac Data Compare

            Source: \(comparison.sourceDescription)
            Target: \(comparison.targetDescription)
            Date:   \(formatter.string(from: Date()))

            Back up the target database before running this script.
        */

        """
    }
}
