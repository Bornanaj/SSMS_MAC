import Foundation

/// A key or index declared inside a table type.
public struct TableTypeIndex: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case primaryKey
        case unique
        case index
    }

    public var kind: Kind
    public var name: String
    public var isUnique: Bool
    public var isClustered: Bool
    public var columns: [IndexColumn]
    public var ignoreDupKey: Bool

    public init(kind: Kind, name: String = "", isUnique: Bool = false, isClustered: Bool,
                columns: [IndexColumn], ignoreDupKey: Bool = false) {
        self.kind = kind
        self.name = name
        self.isUnique = isUnique
        self.isClustered = isClustered
        self.columns = columns
        self.ignoreDupKey = ignoreDupKey
    }
}

/// Renders `SchemaObject`s as T-SQL.
///
/// The same writer produces the text shown in the SQL differences pane, the files of a
/// scripts folder and the statements of a deployment script, so a difference the user sees
/// is exactly a difference the deployment acts on.
public struct SchemaScriptWriter: Sendable {

    public struct Options: Sendable, Hashable {
        public var includePermissions: Bool
        public var includeExtendedProperties: Bool
        public var includeSetOptions: Bool
        public var includeRoleMemberships: Bool
        /// ON filegroup / partition scheme clauses. Off when filegroups are ignored, so objects
        /// land on the target's default filegroup.
        public var includeStorage: Bool

        public init(includePermissions: Bool = true, includeExtendedProperties: Bool = true,
                    includeSetOptions: Bool = true, includeRoleMemberships: Bool = true,
                    includeStorage: Bool = true) {
            self.includePermissions = includePermissions
            self.includeExtendedProperties = includeExtendedProperties
            self.includeSetOptions = includeSetOptions
            self.includeRoleMemberships = includeRoleMemberships
            self.includeStorage = includeStorage
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    static let go = "GO"

    // MARK: - Whole objects

    /// The complete creation script of one object, batches separated by GO.
    public func script(for object: SchemaObject) -> String {
        batches(for: object).map { $0 + "\n\(Self.go)\n" }.joined()
    }

    /// The creation script as individual batches.
    public func batches(for object: SchemaObject) -> [String] {
        var out: [String] = []
        switch object.type {
        case .table:
            out.append(contentsOf: tableBatches(object, includeForeignKeys: true))
        case .view, .function, .storedProcedure, .rule, .defaultObject:
            out.append(contentsOf: moduleBatches(object, verb: "CREATE"))
            out.append(contentsOf: indexAndTriggerBatches(object))
        case .ddlTrigger:
            out.append(contentsOf: moduleBatches(object, verb: "CREATE"))
            if !object.triggerOrder.isEmpty || object.subtype == "disabled" {
                out.append(contentsOf: ddlTriggerStateBatches(object))
            }
        case .schema:
            out.append("CREATE SCHEMA \(SQLIdentifier.quote(object.name)) AUTHORIZATION "
                       + SQLIdentifier.quote(object.owner ?? "dbo"))
        case .role:
            out.append("CREATE ROLE \(SQLIdentifier.quote(object.name)) AUTHORIZATION "
                       + SQLIdentifier.quote(object.owner ?? "dbo"))
        default:
            let body = object.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { out.append(body) }
        }
        if let owner = object.owner, !owner.isEmpty, object.type != .schema,
           object.type != .user, object.type != .role, object.type != .applicationRole {
            out.append(authorizationStatement(object, owner: owner))
        }
        if options.includeRoleMemberships {
            for role in object.roleMemberships.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                out.append(addRoleMemberStatement(role: role, member: object.name))
            }
        }
        if options.includePermissions {
            out.append(contentsOf: object.permissions.sorted().map { permissionStatement($0, on: object) })
        }
        if options.includeExtendedProperties {
            out.append(contentsOf: object.extendedProperties.sorted().map {
                extendedPropertyStatement(procedure: "sp_addextendedproperty", property: $0, on: object)
            })
        }
        return out
    }

    // MARK: - Tables

    public func tableBatches(_ object: SchemaObject, includeForeignKeys: Bool) -> [String] {
        guard let table = object.table else { return [] }
        var out: [String] = [createTableStatement(object, name: object.quotedName)]
        out.append(contentsOf: tablePostCreateBatches(object, table: table, target: object.quotedName))
        if includeForeignKeys {
            for key in table.foreignKeys.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                out.append(contentsOf: foreignKeyBatches(key, table: object.quotedName))
            }
        }
        return out
    }

    /// Everything that follows CREATE TABLE except foreign keys: untrusted checks, indexes,
    /// statistics, triggers, full-text index, change tracking, bindings.
    public func tablePostCreateBatches(_ object: SchemaObject, table: TableDefinition,
                                       target: String, includeFullText: Bool = true) -> [String] {
        var out: [String] = []
        for check in table.checkConstraints where check.isNotTrusted || check.isDisabled {
            out.append(contentsOf: checkConstraintBatches(check, table: target))
        }
        if table.lockEscalation.uppercased() != "TABLE", !table.isMemoryOptimized {
            out.append("ALTER TABLE \(target) SET (LOCK_ESCALATION = \(table.lockEscalation.uppercased()))")
        }
        if table.changeTracking {
            out.append(changeTrackingStatement(target: target, enable: true,
                                               trackColumns: table.changeTrackingColumnsUpdated))
        }
        for column in table.columns {
            if let rule = column.boundRule {
                out.append("EXEC sp_bindrule \(SQLIdentifier.literal(rule)), "
                           + "\(SQLIdentifier.literal(target + "." + SQLIdentifier.quote(column.name)))")
            }
            if let bound = column.boundDefault {
                out.append("EXEC sp_bindefault \(SQLIdentifier.literal(bound)), "
                           + "\(SQLIdentifier.literal(target + "." + SQLIdentifier.quote(column.name)))")
            }
        }
        out.append(contentsOf: indexAndTriggerBatches(object, target: target))
        if includeFullText, let fullText = table.fullTextIndex {
            out.append(createFullTextIndexStatement(fullText, table: target))
        }
        return out
    }

    public func createTableStatement(_ object: SchemaObject, name: String,
                                     includeTrustedChecks: Bool = true) -> String {
        guard let table = object.table else { return "" }
        var lines: [String] = table.columns.map { "    " + columnDefinition($0) }
        if let temporal = table.temporal {
            lines.append("    PERIOD FOR SYSTEM_TIME (\(SQLIdentifier.quote(temporal.periodStartColumn)), "
                         + "\(SQLIdentifier.quote(temporal.periodEndColumn)))")
        }
        if let primaryKey = table.primaryKey {
            lines.append("    " + keyConstraintClause(primaryKey, memoryOptimized: table.isMemoryOptimized))
        }
        for key in table.uniqueConstraints.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            lines.append("    " + keyConstraintClause(key, memoryOptimized: table.isMemoryOptimized))
        }
        if includeTrustedChecks {
            let inline = table.checkConstraints.filter { !$0.isNotTrusted && !$0.isDisabled }
            for check in inline.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                lines.append("    " + checkClause(check))
            }
        }
        if table.isMemoryOptimized {
            for index in object.indexes where index.kind == .nonclustered {
                lines.append("    INDEX \(SQLIdentifier.quote(index.name)) NONCLUSTERED ("
                             + indexColumnList(index.columns) + ")")
            }
        }

        var text = "CREATE TABLE \(name)\n(\n" + lines.joined(separator: ",\n") + "\n)"
        if options.includeStorage, !table.isMemoryOptimized, !table.dataSpace.isEmpty {
            text += " ON " + dataSpaceClause(table.dataSpace, column: table.partitionColumn)
        }
        if options.includeStorage, let lob = table.textImageDataSpace, !lob.isEmpty, !table.isMemoryOptimized {
            text += " TEXTIMAGE_ON \(SQLIdentifier.quote(lob))"
        }
        var with: [String] = []
        if table.dataCompression.uppercased() != "NONE", !table.dataCompression.isEmpty {
            with.append("DATA_COMPRESSION = \(table.dataCompression.uppercased())")
        }
        if table.isMemoryOptimized {
            with.append("MEMORY_OPTIMIZED = ON")
            if let durability = table.durability, !durability.isEmpty {
                with.append("DURABILITY = \(durability.uppercased())")
            }
        }
        if let temporal = table.temporal, let history = temporal.historyTable {
            let historyName = SQLIdentifier.quote(schema: temporal.historySchema ?? object.schema,
                                                  name: history)
            with.append("SYSTEM_VERSIONING = ON (HISTORY_TABLE = \(historyName))")
        }
        if !with.isEmpty {
            text += "\nWITH (" + with.joined(separator: ", ") + ")"
        }
        return text
    }

    public func columnDefinition(_ column: ColumnDefinition, includeDefault: Bool = true) -> String {
        var text = SQLIdentifier.quote(column.name)
        if let expression = column.computedExpression {
            text += " AS " + Self.parenthesized(expression)
            if column.isPersisted {
                text += " PERSISTED"
                if !column.isNullable { text += " NOT NULL" }
            }
            return text
        }
        text += " " + column.dataType
        if column.isColumnSet {
            return text + " COLUMN_SET FOR ALL_SPARSE_COLUMNS"
        }
        if column.isFileStream { text += " FILESTREAM" }
        if let collation = column.collation, !collation.isEmpty { text += " COLLATE \(collation)" }
        if column.isSparse { text += " SPARSE" }
        if let mask = column.maskingFunction, !mask.isEmpty {
            text += " MASKED WITH (FUNCTION = '\(mask.replacingOccurrences(of: "'", with: "''"))')"
        }
        if let identity = column.identity {
            text += " IDENTITY(\(identity.seed), \(identity.increment))"
            if identity.notForReplication { text += " NOT FOR REPLICATION" }
        }
        if let generated = column.generatedAlways {
            text += " GENERATED ALWAYS AS \(generated.uppercased())"
            if column.isHidden { text += " HIDDEN" }
        }
        if column.isRowGuidCol { text += " ROWGUIDCOL" }
        text += column.isNullable ? " NULL" : " NOT NULL"
        if includeDefault, let constraint = column.defaultConstraint {
            if !constraint.isSystemNamed, !constraint.name.isEmpty {
                text += " CONSTRAINT \(SQLIdentifier.quote(constraint.name))"
            }
            text += " DEFAULT " + Self.parenthesized(constraint.definition)
        }
        return text
    }

    public func keyConstraintClause(_ key: KeyConstraintDefinition, memoryOptimized: Bool = false,
                                    extraOptions: [String] = [], storageOverride: String? = nil) -> String {
        var text = ""
        if !key.isSystemNamed, !key.name.isEmpty {
            text += "CONSTRAINT \(SQLIdentifier.quote(key.name)) "
        }
        text += key.isPrimaryKey ? "PRIMARY KEY " : "UNIQUE "
        if memoryOptimized {
            text += "NONCLUSTERED "
        } else {
            text += key.isClustered ? "CLUSTERED " : "NONCLUSTERED "
        }
        text += "(" + indexColumnList(key.columns) + ")"
        if !memoryOptimized {
            let with = indexOptionList(key.options, isColumnstore: false) + extraOptions
            if !with.isEmpty { text += " WITH (" + with.joined(separator: ", ") + ")" }
            if let storageOverride {
                text += " ON " + storageOverride
            } else if options.includeStorage, !key.dataSpace.isEmpty {
                text += " ON " + dataSpaceClause(key.dataSpace, column: key.partitionColumn)
            }
        }
        return text
    }

    public func checkClause(_ check: CheckConstraintDefinition) -> String {
        var text = ""
        if !check.isSystemNamed, !check.name.isEmpty {
            text += "CONSTRAINT \(SQLIdentifier.quote(check.name)) "
        }
        text += "CHECK "
        if check.isNotForReplication { text += "NOT FOR REPLICATION " }
        return text + Self.parenthesized(check.definition)
    }

    public func addKeyConstraintStatement(_ key: KeyConstraintDefinition, table: String,
                                          online: Bool = false, storageOverride: String? = nil) -> String {
        "ALTER TABLE \(table) ADD " + keyConstraintClause(key, extraOptions: online ? ["ONLINE = ON"] : [],
                                                         storageOverride: storageOverride)
    }

    public func checkConstraintBatches(_ check: CheckConstraintDefinition, table: String) -> [String] {
        let with = check.isNotTrusted ? "WITH NOCHECK " : ""
        var out = ["ALTER TABLE \(table) \(with)ADD " + checkClause(check)]
        if check.isDisabled, !check.name.isEmpty {
            out.append("ALTER TABLE \(table) NOCHECK CONSTRAINT \(SQLIdentifier.quote(check.name))")
        }
        return out
    }

    public func foreignKeyBatches(_ key: ForeignKeyDefinition, table: String) -> [String] {
        let with = key.isNotTrusted ? "WITH NOCHECK" : "WITH CHECK"
        var text = "ALTER TABLE \(table) \(with) ADD "
        if !key.isSystemNamed, !key.name.isEmpty {
            text += "CONSTRAINT \(SQLIdentifier.quote(key.name)) "
        }
        text += "FOREIGN KEY (" + key.columns.map(SQLIdentifier.quote).joined(separator: ", ") + ")"
        text += " REFERENCES " + SQLIdentifier.quote(schema: key.referencedSchema, name: key.referencedTable)
        text += " (" + key.referencedColumns.map(SQLIdentifier.quote).joined(separator: ", ") + ")"
        if key.deleteAction.uppercased() != "NO ACTION", !key.deleteAction.isEmpty {
            text += " ON DELETE \(key.deleteAction.uppercased())"
        }
        if key.updateAction.uppercased() != "NO ACTION", !key.updateAction.isEmpty {
            text += " ON UPDATE \(key.updateAction.uppercased())"
        }
        if key.isNotForReplication { text += " NOT FOR REPLICATION" }
        var out = [text]
        if key.isDisabled, !key.name.isEmpty {
            out.append("ALTER TABLE \(table) NOCHECK CONSTRAINT \(SQLIdentifier.quote(key.name))")
        }
        return out
    }

    public func addDefaultStatement(_ constraint: DefaultConstraintDefinition, column: String,
                                    table: String) -> String {
        var text = "ALTER TABLE \(table) ADD "
        if !constraint.isSystemNamed, !constraint.name.isEmpty {
            text += "CONSTRAINT \(SQLIdentifier.quote(constraint.name)) "
        }
        return text + "DEFAULT " + Self.parenthesized(constraint.definition)
            + " FOR \(SQLIdentifier.quote(column))"
    }

    public func dropConstraintStatement(name: String, table: String) -> String {
        "ALTER TABLE \(table) DROP CONSTRAINT \(SQLIdentifier.quote(name))"
    }

    public func changeTrackingStatement(target: String, enable: Bool, trackColumns: Bool) -> String {
        guard enable else { return "ALTER TABLE \(target) DISABLE CHANGE_TRACKING" }
        return "ALTER TABLE \(target) ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = "
            + (trackColumns ? "ON" : "OFF") + ")"
    }

    // MARK: - Indexes, statistics, triggers

    public func indexAndTriggerBatches(_ object: SchemaObject, target: String? = nil) -> [String] {
        let name = target ?? object.quotedName
        var out: [String] = []
        let memoryOptimized = object.table?.isMemoryOptimized ?? false
        // Clustered first, then primary XML before secondary XML, then the rest by name.
        let ordered = object.indexes.sorted { lhs, rhs in
            let left = indexRank(lhs)
            let right = indexRank(rhs)
            if left != right { return left < right }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
        for index in ordered {
            if memoryOptimized && index.kind == .nonclustered { continue }
            out.append(contentsOf: createIndexBatches(index, on: name))
        }
        for statistic in object.statistics.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            out.append(createStatisticsStatement(statistic, on: name))
        }
        for trigger in object.triggers.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            out.append(contentsOf: triggerBatches(trigger, schema: object.schema, target: name))
        }
        return out
    }

    private func indexRank(_ index: IndexDefinition) -> Int {
        switch index.kind {
        case .clustered, .clusteredColumnstore: return 0
        case .primaryXml: return 2
        case .secondaryXml: return 3
        default: return 1
        }
    }

    public func createIndexBatches(_ index: IndexDefinition, on target: String,
                                   online: Bool = false, storageOverride: String? = nil) -> [String] {
        var out = [createIndexStatement(index, on: target, online: online, storageOverride: storageOverride)]
        if index.isDisabled {
            out.append("ALTER INDEX \(SQLIdentifier.quote(index.name)) ON \(target) DISABLE")
        }
        return out
    }

    public func createIndexStatement(_ index: IndexDefinition, on target: String,
                                     online: Bool = false, storageOverride: String? = nil) -> String {
        let name = SQLIdentifier.quote(index.name)
        var text: String
        switch index.kind {
        case .primaryXml:
            text = "CREATE PRIMARY XML INDEX \(name) ON \(target) (" + indexColumnList(index.columns) + ")"
        case .secondaryXml:
            text = "CREATE XML INDEX \(name) ON \(target) (" + indexColumnList(index.columns) + ")"
            if let primary = index.primaryXmlIndex {
                text += " USING XML INDEX \(SQLIdentifier.quote(primary))"
                if let type = index.secondaryXmlType { text += " FOR \(type.uppercased())" }
            }
        case .spatial:
            text = "CREATE SPATIAL INDEX \(name) ON \(target) (" + indexColumnList(index.columns) + ")"
            if let tessellation = index.spatialTessellation { text += " USING \(tessellation)" }
        case .clusteredColumnstore:
            text = "CREATE CLUSTERED COLUMNSTORE INDEX \(name) ON \(target)"
        case .nonclusteredColumnstore:
            text = "CREATE NONCLUSTERED COLUMNSTORE INDEX \(name) ON \(target) ("
                + index.includedColumns.map(SQLIdentifier.quote).joined(separator: ", ") + ")"
        case .clustered, .nonclustered:
            text = "CREATE " + (index.isUnique ? "UNIQUE " : "")
                + (index.kind == .clustered ? "CLUSTERED" : "NONCLUSTERED")
                + " INDEX \(name) ON \(target) (" + indexColumnList(index.columns) + ")"
            if !index.includedColumns.isEmpty {
                text += " INCLUDE (" + index.includedColumns.map(SQLIdentifier.quote).joined(separator: ", ") + ")"
            }
        }
        if let filter = index.filter, !filter.isEmpty,
           index.kind == .nonclustered || index.kind == .nonclusteredColumnstore {
            text += " WHERE " + filter
        }
        let isColumnstore = index.kind == .clusteredColumnstore || index.kind == .nonclusteredColumnstore
        var with = indexOptionList(index.options, isColumnstore: isColumnstore)
        if index.kind == .spatial, let spatialOptions = index.spatialBoundingBox, !spatialOptions.isEmpty {
            // The reader stores the complete spatial WITH fragment: bounding box, grids, cells.
            with.insert(spatialOptions, at: 0)
        }
        if online, index.kind != .spatial, index.kind != .primaryXml, index.kind != .secondaryXml {
            with.append("ONLINE = ON")
        }
        if !with.isEmpty { text += " WITH (" + with.joined(separator: ", ") + ")" }
        let dataSpaceAllowed = index.kind != .secondaryXml && index.kind != .primaryXml
            && index.kind != .spatial
        if dataSpaceAllowed, let storageOverride {
            text += " ON " + storageOverride
        } else if dataSpaceAllowed, options.includeStorage, !index.dataSpace.isEmpty {
            text += " ON " + dataSpaceClause(index.dataSpace, column: index.partitionColumn)
        }
        return text
    }

    public func dropIndexStatement(name: String, on target: String) -> String {
        "DROP INDEX \(SQLIdentifier.quote(name)) ON \(target)"
    }

    public func createStatisticsStatement(_ statistic: StatisticsDefinition, on target: String) -> String {
        var text = "CREATE STATISTICS \(SQLIdentifier.quote(statistic.name)) ON \(target) ("
            + statistic.columns.map(SQLIdentifier.quote).joined(separator: ", ") + ")"
        if let filter = statistic.filter, !filter.isEmpty { text += " WHERE " + filter }
        if statistic.noRecompute { text += " WITH NORECOMPUTE" }
        return text
    }

    public func triggerBatches(_ trigger: TriggerDefinition, schema: String, target: String) -> [String] {
        var out: [String] = []
        if options.includeSetOptions {
            out.append("SET QUOTED_IDENTIFIER \(trigger.usesQuotedIdentifier ? "ON" : "OFF")")
            out.append("SET ANSI_NULLS \(trigger.usesAnsiNulls ? "ON" : "OFF")")
        }
        let quotedTrigger = SQLIdentifier.quote(schema: schema, name: trigger.name)
        let text = ModuleText.rewrite(trigger.definition, verb: "CREATE", quotedName: quotedTrigger,
                                      triggerTarget: target)
        out.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trigger.isDisabled {
            out.append("DISABLE TRIGGER \(quotedTrigger) ON \(target)")
        }
        for event in trigger.order.keys.sorted() {
            let order = trigger.order[event] ?? "None"
            out.append("EXEC sp_settriggerorder N'\(escape(quotedTrigger))', "
                       + "N'\(order)', N'\(event.uppercased())'")
        }
        return out
    }

    public func createFullTextIndexStatement(_ index: FullTextIndexDefinition, table: String) -> String {
        let columns = index.columns.map { column -> String in
            var text = SQLIdentifier.quote(column.name)
            if let type = column.typeColumn { text += " TYPE COLUMN \(SQLIdentifier.quote(type))" }
            if let language = column.language { text += " LANGUAGE \(language)" }
            return text
        }
        var text = "CREATE FULLTEXT INDEX ON \(table) (" + columns.joined(separator: ", ") + ")"
        text += " KEY INDEX \(SQLIdentifier.quote(index.keyIndex))"
        if !index.catalog.isEmpty { text += " ON \(SQLIdentifier.quote(index.catalog))" }
        var with = ["CHANGE_TRACKING = \(index.changeTracking.uppercased())"]
        if let stoplist = index.stoplist {
            let upper = stoplist.uppercased()
            with.append("STOPLIST = " + (upper == "SYSTEM" || upper == "OFF" ? upper : SQLIdentifier.quote(stoplist)))
        }
        return text + " WITH (" + with.joined(separator: ", ") + ")"
    }

    // MARK: - Modules

    public func moduleBatches(_ object: SchemaObject, verb: String) -> [String] {
        var out: [String] = []
        if object.isEncrypted {
            out.append("/* \(object.type.title) \(object.quotedName) is encrypted and its definition "
                       + "cannot be read. */")
            return out
        }
        if options.includeSetOptions {
            out.append("SET QUOTED_IDENTIFIER \(object.usesQuotedIdentifier ? "ON" : "OFF")")
            out.append("SET ANSI_NULLS \(object.usesAnsiNulls ? "ON" : "OFF")")
        }
        out.append(moduleText(object, verb: verb))
        return out
    }

    /// The definition with its header rewritten to `verb` and the object's current name.
    public func moduleText(_ object: SchemaObject, verb: String) -> String {
        let quoted: String = object.type == .ddlTrigger ? SQLIdentifier.quote(object.name) : object.quotedName
        return ModuleText.rewrite(object.body, verb: verb, quotedName: quoted)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ddlTriggerStateBatches(_ object: SchemaObject) -> [String] {
        var out: [String] = []
        if object.subtype == "disabled" {
            out.append("DISABLE TRIGGER \(SQLIdentifier.quote(object.name)) ON DATABASE")
        }
        for event in object.triggerOrder.keys.sorted() {
            out.append("EXEC sp_settriggerorder N'\(escape(SQLIdentifier.quote(object.name)))', "
                       + "N'\(object.triggerOrder[event] ?? "None")', N'\(event.uppercased())', "
                       + "N'DATABASE'")
        }
        return out
    }

    // MARK: - Security and documentation

    /// The securable as it appears after ON, e.g. `[dbo].[T]`, `SCHEMA::[sales]`.
    public func securable(for object: SchemaObject) -> String? {
        switch object.type {
        case .user, .role, .applicationRole: return nil
        case .schema: return "SCHEMA::" + SQLIdentifier.quote(object.name)
        case .userDefinedType, .tableType: return "TYPE::" + object.quotedName
        case .xmlSchemaCollection: return "XML SCHEMA COLLECTION::" + object.quotedName
        case .assembly: return "ASSEMBLY::" + SQLIdentifier.quote(object.name)
        case .fullTextCatalog: return "FULLTEXT CATALOG::" + SQLIdentifier.quote(object.name)
        case .fullTextStoplist: return "FULLTEXT STOPLIST::" + SQLIdentifier.quote(object.name)
        case .messageType: return "MESSAGE TYPE::" + SQLIdentifier.quote(object.name)
        case .contract: return "CONTRACT::" + SQLIdentifier.quote(object.name)
        case .service: return "SERVICE::" + SQLIdentifier.quote(object.name)
        case .partitionFunction, .partitionScheme, .ddlTrigger: return nil
        default: return object.quotedName
        }
    }

    public func permissionStatement(_ permission: PermissionDefinition, on object: SchemaObject) -> String {
        let verb = permission.state.uppercased().hasPrefix("DENY") ? "DENY" : "GRANT"
        var text = "\(verb) \(permission.permission.uppercased())"
        if let target = securable(for: object) {
            text += " ON \(target)"
            if let column = permission.column, !column.isEmpty {
                text += " (\(SQLIdentifier.quote(column)))"
            }
        }
        let grantee = isPrincipal(object) ? object.name : permission.grantee
        text += " TO \(SQLIdentifier.quote(grantee))"
        if permission.state.uppercased() == "GRANT_WITH_GRANT_OPTION" { text += " WITH GRANT OPTION" }
        return text
    }

    public func revokeStatement(_ permission: PermissionDefinition, on object: SchemaObject) -> String {
        var text = "REVOKE \(permission.permission.uppercased())"
        if let target = securable(for: object) {
            text += " ON \(target)"
            if let column = permission.column, !column.isEmpty {
                text += " (\(SQLIdentifier.quote(column)))"
            }
        }
        let grantee = isPrincipal(object) ? object.name : permission.grantee
        text += " FROM \(SQLIdentifier.quote(grantee))"
        if permission.state.uppercased() == "GRANT_WITH_GRANT_OPTION" { text += " CASCADE" }
        return text
    }

    private func isPrincipal(_ object: SchemaObject) -> Bool {
        object.type == .user || object.type == .role || object.type == .applicationRole
    }

    /// `procedure` is `sp_addextendedproperty`, `sp_updateextendedproperty` or
    /// `sp_dropextendedproperty`.
    public func extendedPropertyStatement(procedure: String, property: ExtendedPropertyDefinition,
                                          on object: SchemaObject) -> String {
        var arguments: [String] = [SQLIdentifier.literal(property.name)]
        if procedure != "sp_dropextendedproperty" {
            arguments.append(SQLIdentifier.literal(property.value))
        }
        let levels = extendedPropertyLevels(object, property: property)
        for (type, name) in levels {
            arguments.append("'\(type)'")
            arguments.append(SQLIdentifier.literal(name))
        }
        return "EXEC sys.\(procedure) " + arguments.joined(separator: ", ")
    }

    func extendedPropertyLevels(_ object: SchemaObject,
                                property: ExtendedPropertyDefinition) -> [(String, String)] {
        var levels: [(String, String)] = []
        switch object.type {
        case .schema:
            levels.append(("SCHEMA", object.name))
        case .user, .role, .applicationRole:
            levels.append(("USER", object.name))
        case .ddlTrigger:
            levels.append(("TRIGGER", object.name))
        case .assembly:
            levels.append(("ASSEMBLY", object.name))
        case .partitionFunction:
            levels.append(("PARTITION FUNCTION", object.name))
        case .partitionScheme:
            levels.append(("PARTITION SCHEME", object.name))
        case .messageType:
            levels.append(("MESSAGE TYPE", object.name))
        case .contract:
            levels.append(("CONTRACT", object.name))
        case .service:
            levels.append(("SERVICE", object.name))
        default:
            levels.append(("SCHEMA", object.schema))
            let level1: String = object.type == .tableType ? "TYPE" : (object.type.extendedPropertyLevel1 ?? "TABLE")
            levels.append((level1, object.name))
        }
        if let childType = property.childType, let childName = property.childName {
            levels.append((childType.uppercased(), childName))
        }
        return levels
    }

    public func authorizationStatement(_ object: SchemaObject, owner: String) -> String {
        let target: String
        if let securable = securable(for: object), securable.contains("::") {
            target = securable
        } else {
            target = "OBJECT::" + object.quotedName
        }
        return "ALTER AUTHORIZATION ON \(target) TO \(SQLIdentifier.quote(owner))"
    }

    public func addRoleMemberStatement(role: String, member: String) -> String {
        "ALTER ROLE \(SQLIdentifier.quote(role)) ADD MEMBER \(SQLIdentifier.quote(member))"
    }

    public func dropRoleMemberStatement(role: String, member: String) -> String {
        "ALTER ROLE \(SQLIdentifier.quote(role)) DROP MEMBER \(SQLIdentifier.quote(member))"
    }

    // MARK: - Drops

    public func dropStatement(for object: SchemaObject) -> String {
        dropStatement(type: object.type, schema: object.schema, name: object.name)
    }

    public func dropStatement(type: SchemaObjectType, schema: String, name: String) -> String {
        let key = SchemaObjectKey(type: type, schema: schema, name: name)
        switch type {
        case .ddlTrigger:
            return "DROP TRIGGER \(SQLIdentifier.quote(name)) ON DATABASE"
        case .user, .role, .applicationRole, .schema, .assembly, .partitionFunction,
             .partitionScheme, .fullTextCatalog, .fullTextStoplist, .messageType, .contract,
             .service:
            return "DROP \(type.dropKeyword) \(SQLIdentifier.quote(name))"
        default:
            return "DROP \(type.dropKeyword) \(key.quotedName)"
        }
    }

    // MARK: - Table types

    /// Canonical CREATE TYPE … AS TABLE text, shared by the live reader and the script parser
    /// so both produce identical bodies.
    public func tableTypeBody(quotedName: String, columns: [ColumnDefinition], indexes: [TableTypeIndex],
                              checks: [String], memoryOptimized: Bool) -> String {
        var lines: [String] = columns.map { column -> String in
            var copy = column
            if copy.defaultConstraint != nil {
                copy.defaultConstraint?.name = ""
                copy.defaultConstraint?.isSystemNamed = true
            }
            return "    " + columnDefinition(copy)
        }
        for index in indexes {
            let list = indexColumnList(index.columns)
            let clustered = index.isClustered ? "CLUSTERED" : "NONCLUSTERED"
            let ignoreDup = index.ignoreDupKey ? " WITH (IGNORE_DUP_KEY = ON)" : ""
            switch index.kind {
            case .primaryKey: lines.append("    PRIMARY KEY \(clustered) (\(list))\(ignoreDup)")
            case .unique: lines.append("    UNIQUE \(clustered) (\(list))\(ignoreDup)")
            case .index:
                let unique = index.isUnique ? "UNIQUE " : ""
                lines.append("    INDEX \(SQLIdentifier.quote(index.name)) \(unique)\(clustered) (\(list))")
            }
        }
        for check in checks {
            lines.append("    CHECK " + SchemaScriptWriter.parenthesized(check))
        }
        var body = "CREATE TYPE \(quotedName) AS TABLE\n(\n" + lines.joined(separator: ",\n") + "\n)"
        if memoryOptimized { body += "\nWITH (MEMORY_OPTIMIZED = ON)" }
        return body
    }

    // MARK: - Pieces

    public func indexColumnList(_ columns: [IndexColumn]) -> String {
        columns.map { SQLIdentifier.quote($0.name) + ($0.isDescending ? " DESC" : "") }
            .joined(separator: ", ")
    }

    func indexOptionList(_ options: IndexOptions, isColumnstore: Bool) -> [String] {
        var out: [String] = []
        if isColumnstore {
            let compression = options.dataCompression.uppercased()
            if compression == "COLUMNSTORE_ARCHIVE" { out.append("DATA_COMPRESSION = COLUMNSTORE_ARCHIVE") }
            return out
        }
        if options.padIndex { out.append("PAD_INDEX = ON") }
        if options.effectiveFillFactor > 0 { out.append("FILLFACTOR = \(options.effectiveFillFactor)") }
        if options.ignoreDupKey { out.append("IGNORE_DUP_KEY = ON") }
        if options.statisticsNoRecompute { out.append("STATISTICS_NORECOMPUTE = ON") }
        if !options.allowRowLocks { out.append("ALLOW_ROW_LOCKS = OFF") }
        if !options.allowPageLocks { out.append("ALLOW_PAGE_LOCKS = OFF") }
        if options.optimizeForSequentialKey { out.append("OPTIMIZE_FOR_SEQUENTIAL_KEY = ON") }
        let compression = options.dataCompression.uppercased()
        if !compression.isEmpty, compression != "NONE" { out.append("DATA_COMPRESSION = \(compression)") }
        return out
    }

    func dataSpaceClause(_ dataSpace: String, column: String?) -> String {
        if let column, !column.isEmpty {
            return SQLIdentifier.quote(dataSpace) + " (" + SQLIdentifier.quote(column) + ")"
        }
        return SQLIdentifier.quote(dataSpace)
    }

    /// Wrap an expression in one pair of parentheses unless it already has a balanced pair
    /// around the whole thing.
    public static func parenthesized(_ expression: String) -> String {
        let value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("("), value.hasSuffix(")"), wrapsWhole(value) { return value }
        return "(\(value))"
    }

    private static func wrapsWhole(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            if character == "'" { inString.toggle(); continue }
            if inString { continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 && offset != characters.count - 1 { return false }
            }
        }
        return depth == 0
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }
}
