import Foundation
import TDSKit

/// Compares the rows of mapped tables.
///
/// Each table is read once from each side. The target's rows go into a dictionary keyed by
/// the comparison key; the source's rows are then streamed past it, so memory holds one
/// table's target rows plus the differences, never both tables in full.
public struct DataComparer: Sendable {
    public let sourceSession: SQLServerSession
    public let sourceDatabase: String
    public let targetSession: SQLServerSession
    public let targetDatabase: String
    public let options: DataCompareOptions

    public typealias Progress = @Sendable (Int, Int, String) -> Void

    public init(sourceSession: SQLServerSession, sourceDatabase: String, targetSession: SQLServerSession,
                targetDatabase: String, options: DataCompareOptions) {
        self.sourceSession = sourceSession
        self.sourceDatabase = sourceDatabase
        self.targetSession = targetSession
        self.targetDatabase = targetDatabase
        self.options = options
    }

    public func compare(_ mappings: [DataTableMapping], targetForeignKeys: [DataForeignKeyInfo] = [],
                        progress: Progress? = nil) async throws -> DataComparison {
        let started = Date()
        let sourceConnection = try await open(sourceSession, database: sourceDatabase)
        let targetConnection = try await open(targetSession, database: targetDatabase)
        defer {
            Task {
                try? await sourceConnection.close()
                try? await targetConnection.close()
            }
        }
        let included = mappings.filter(\.isIncluded)
        var tables: [DataTableResult] = []
        for (index, mapping) in included.enumerated() {
            try Task.checkCancellation()
            progress?(index, included.count, mapping.displayName)
            let tableStarted = Date()
            var result: DataTableResult
            do {
                result = try await compareTable(mapping, source: sourceConnection, target: targetConnection)
            } catch let error as CancellationError {
                throw error
            } catch {
                result = DataTableResult(mapping: mapping)
                result.error = Self.describe(error)
            }
            result.duration = Date().timeIntervalSince(tableStarted)
            tables.append(result)
        }
        progress?(included.count, included.count, "Done")
        let sourceInfo = await sourceSession.serverInfo
        let targetInfo = await targetSession.serverInfo
        return DataComparison(sourceDescription: "\(sourceInfo.serverName)/\(sourceDatabase)",
                              targetDescription: "\(targetInfo.serverName)/\(targetDatabase)",
                              sourceDatabase: sourceDatabase, targetDatabase: targetDatabase, options: options,
                              tables: tables, targetForeignKeys: targetForeignKeys, comparedAt: Date(),
                              duration: Date().timeIntervalSince(started))
    }

    private func open(_ session: SQLServerSession, database: String) async throws -> TDSConnection {
        let connection = try await session.openConnection(database: database)
        let info = await session.serverInfo
        if !info.isAzureSQLDatabase, !database.isEmpty {
            _ = try await connection.query("USE \(SQLIdentifier.quote(database))")
        }
        return connection
    }

    // MARK: - One table

    public func compareTable(_ mapping: DataTableMapping, source: TDSConnection,
                             target: TDSConnection) async throws -> DataTableResult {
        var result = DataTableResult(mapping: mapping)
        let keys = mapping.keyColumns
        let compared = mapping.comparedColumns
        guard !keys.isEmpty else {
            result.error = "No comparison key: choose a primary key, unique index or custom key."
            return result
        }
        let comparer = DataValueComparer(options: options)
        let rules = (keys + compared).map { comparer.rule(for: $0) }
        let keyRules = Array(rules.prefix(keys.count))

        if options.useChecksumComparison {
            let sourceSum = try await checksum(source, table: mapping.source,
                                               columns: (keys + compared).map(\.sourceColumn), where: mapping.sourceWhere)
            let targetSum = try await checksum(target, table: mapping.target,
                                               columns: (keys + compared).map(\.targetColumn), where: mapping.targetWhere)
            if let sourceSum, let targetSum, sourceSum == targetSum {
                result.sourceRows = sourceSum.0
                result.targetRows = targetSum.0
                result.identical = sourceSum.0
                result.comparedByChecksum = true
                return result
            }
        }

        let store = TargetRowStore(comparer: comparer, keyRules: keyRules, keyCount: keys.count)
        let targetSQL = selectStatement(table: mapping.target, columns: (keys + compared).map(\.targetColumn),
                                        where: mapping.targetWhere)
        try await stream(target, targetSQL) { row in store.add(row) }

        let processor = SourceRowProcessor(store: store, comparer: comparer, rules: rules, keyCount: keys.count,
                                           limit: max(1, options.maximumRowsKept),
                                           keepIdentical: options.keepIdenticalRows)
        let sourceSQL = selectStatement(table: mapping.source, columns: (keys + compared).map(\.sourceColumn),
                                        where: mapping.sourceWhere)
        try await stream(source, sourceSQL) { row in processor.process(row) }

        let outcome = processor.finish()
        result.sourceRows = outcome.sourceRows
        result.targetRows = store.count
        result.identical = outcome.identical
        result.different = outcome.different
        result.onlyInSource = outcome.onlyInSource
        result.onlyInTarget = outcome.onlyInTarget
        result.rows = outcome.rows
        result.isTruncated = outcome.truncated
        if store.duplicates > 0 {
            result.notes.append("\(store.duplicates) target row(s) share a key value with another row; the comparison "
                                + "key is not unique there.")
        }
        if outcome.duplicates > 0 {
            result.notes.append("\(outcome.duplicates) source row(s) share a key value with another row.")
        }
        if outcome.truncated {
            result.notes.append("Only the first \(options.maximumRowsKept) rows of each kind are kept for display "
                                + "and deployment.")
        }
        if options.reseedIdentityColumns, mapping.source.columns.contains(where: \.isIdentity) {
            let sql = "SELECT CONVERT(bigint, IDENT_CURRENT(\(SQLIdentifier.literal(mapping.source.quotedName)))) AS v"
            result.sourceIdentity = try? await source.query(sql).resultSets.first?.rows.first?.first
        }
        return result
    }

    func selectStatement(table: DataTableInfo, columns: [String], where condition: String) -> String {
        var sql = "SELECT " + columns.map(SQLIdentifier.quote).joined(separator: ", ")
            + " FROM " + table.quotedName
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sql += " WHERE " + trimmed }
        return sql
    }

    private func checksum(_ connection: TDSConnection, table: DataTableInfo, columns: [String],
                          where condition: String) async throws -> (Int, Int64)? {
        var sql = "SELECT COUNT_BIG(*) AS c, CONVERT(bigint, CHECKSUM_AGG(BINARY_CHECKSUM("
            + columns.map(SQLIdentifier.quote).joined(separator: ", ") + "))) AS h FROM " + table.quotedName
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sql += " WHERE " + trimmed }
        guard let row = try await connection.query(sql).resultSets.first?.dictionaries().first else { return nil }
        return (row.int("c"), row.int64("h"))
    }

    private func stream(_ connection: TDSConnection, _ sql: String,
                        _ handle: @escaping @Sendable ([TDSValue]) -> Void) async throws {
        let errors = MessageBox()
        try await withTaskCancellationHandler {
            try await connection.execute(sql) { event in
                switch event {
                case .row(let values): handle(values)
                case .error(let message): errors.append(message)
                default: break
                }
            }
        } onCancel: {
            connection.cancel()
        }
        try Task.checkCancellation()
        if let failure = errors.first { throw TDSError.server(failure) }
    }

    static func describe(_ error: Error) -> String {
        if case TDSError.server(let message) = error { return message.text }
        if let message = error as? TDSServerMessage { return message.text }
        return String(describing: error)
    }
}

// MARK: - Row stores

/// Target rows by key. Filled on the connection's event loop, then consumed as source rows
/// arrive, hence the lock.
final class TargetRowStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: [TDSValue]] = [:]
    private var order: [String] = []
    private(set) var count = 0
    private(set) var duplicates = 0
    let comparer: DataValueComparer
    let keyRules: [DataValueComparer.TextRule]
    let keyCount: Int

    init(comparer: DataValueComparer, keyRules: [DataValueComparer.TextRule], keyCount: Int) {
        self.comparer = comparer
        self.keyRules = keyRules
        self.keyCount = keyCount
    }

    func add(_ values: [TDSValue]) {
        let key = comparer.key(values.prefix(keyCount), rules: keyRules)
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if rows.updateValue(values, forKey: key) != nil {
            duplicates += 1
        } else {
            order.append(key)
        }
    }

    /// Removes and returns the row with this key.
    func take(_ key: String) -> [TDSValue]? {
        lock.lock()
        defer { lock.unlock() }
        return rows.removeValue(forKey: key)
    }

    /// Rows nobody asked for: they exist only in the target. Returned in read order.
    func remaining() -> [[TDSValue]] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { rows[$0] }
    }

    var remainingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.count
    }
}

final class SourceRowProcessor: @unchecked Sendable {
    struct Outcome {
        var sourceRows = 0
        var identical = 0
        var different = 0
        var onlyInSource = 0
        var onlyInTarget = 0
        var duplicates = 0
        var truncated = false
        var rows: [DataRowDifference] = []
    }

    private let lock = NSLock()
    private let store: TargetRowStore
    private let comparer: DataValueComparer
    private let rules: [DataValueComparer.TextRule]
    private let keyCount: Int
    private let limit: Int
    private let keepIdentical: Bool
    private var outcome = Outcome()
    private var kept: [DataRowStatus: Int] = [:]
    private var seen: Set<String> = []
    private var nextID = 0

    init(store: TargetRowStore, comparer: DataValueComparer, rules: [DataValueComparer.TextRule], keyCount: Int,
         limit: Int, keepIdentical: Bool) {
        self.store = store
        self.comparer = comparer
        self.rules = rules
        self.keyCount = keyCount
        self.limit = limit
        self.keepIdentical = keepIdentical
    }

    func process(_ values: [TDSValue]) {
        let keyRules = Array(rules.prefix(keyCount))
        let key = comparer.key(values.prefix(keyCount), rules: keyRules)
        lock.lock()
        defer { lock.unlock() }
        outcome.sourceRows += 1
        guard seen.insert(key).inserted else {
            outcome.duplicates += 1
            return
        }
        let keyValues = Array(values.prefix(keyCount))
        let sourceValues = Array(values.dropFirst(keyCount))
        guard let targetRow = store.take(key) else {
            outcome.onlyInSource += 1
            keep(.onlyInSource, key: keyValues, source: sourceValues, target: nil, differing: [])
            return
        }
        let targetValues = Array(targetRow.dropFirst(keyCount))
        var differing: [Int] = []
        for index in sourceValues.indices where index < targetValues.count {
            let rule = keyCount + index < rules.count ? rules[keyCount + index] : .exact
            if !comparer.equal(sourceValues[index], targetValues[index], rule: rule) {
                differing.append(index)
            }
        }
        if differing.isEmpty {
            outcome.identical += 1
            if keepIdentical {
                keep(.identical, key: keyValues, source: sourceValues, target: targetValues, differing: [])
            }
        } else {
            outcome.different += 1
            keep(.different, key: keyValues, source: sourceValues, target: targetValues, differing: differing)
        }
    }

    private func keep(_ status: DataRowStatus, key: [TDSValue], source: [TDSValue]?, target: [TDSValue]?,
                      differing: [Int]) {
        let count = kept[status, default: 0]
        guard count < limit else {
            outcome.truncated = true
            return
        }
        kept[status] = count + 1
        outcome.rows.append(DataRowDifference(id: nextID, status: status, key: key, source: source, target: target,
                                              differingColumns: differing, isSelected: status != .identical))
        nextID += 1
    }

    func finish() -> Outcome {
        let leftovers = store.remaining()
        lock.lock()
        defer { lock.unlock() }
        for row in leftovers {
            outcome.onlyInTarget += 1
            keep(.onlyInTarget, key: Array(row.prefix(keyCount)), source: nil, target: Array(row.dropFirst(keyCount)),
                 differing: [])
        }
        return outcome
    }
}

final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [TDSServerMessage] = []

    func append(_ message: TDSServerMessage) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var first: TDSServerMessage? {
        lock.lock()
        defer { lock.unlock() }
        return messages.first { $0.severity >= 11 }
    }
}
