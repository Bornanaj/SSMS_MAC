import Foundation

/// Applies the comparison options to objects.
///
/// Two forms come out of it. The *prepared* form drops what the options say to ignore and is
/// what gets displayed and deployed — an ignored collation is neither shown nor scripted. The
/// *fingerprint* goes further and erases what should not count as a difference but must still
/// be deployed faithfully (seed values, generated constraint names, whitespace), then encodes
/// the result so two objects compare with one string comparison.
public struct SchemaNormalizer: Sendable {
    public let options: SchemaCompareOptions
    /// Collation assumed for character columns whose collation is not known, typically ones
    /// parsed from scripts that did not spell it out.
    public let defaultCollation: String

    public init(options: SchemaCompareOptions, defaultCollation: String) {
        self.options = options
        self.defaultCollation = defaultCollation
    }

    // MARK: - Prepared form

    public func prepared(_ input: SchemaObject) -> SchemaObject {
        var object = input
        let isPrincipal = object.type == .user || object.type == .role || object.type == .applicationRole
        if options.ignorePermissions || (isPrincipal && options.ignoreUsersPermissionsAndRoleMemberships) {
            object.permissions = []
        }
        if isPrincipal && options.ignoreUsersPermissionsAndRoleMemberships {
            object.roleMemberships = []
        }
        if options.ignoreExtendedProperties { object.extendedProperties = [] }
        if options.ignoreAuthorization {
            object.owner = nil
            if object.type == .role { object.owner = "dbo" }
        }
        if options.ignoreStatistics { object.statistics = [] }
        if options.ignoreDMLTriggers { object.triggers = [] }
        if options.ignoreTriggerOrder {
            object.triggerOrder = [:]
            for index in object.triggers.indices { object.triggers[index].order = [:] }
        }
        if options.ignoreIndexes {
            object.indexes = []
        } else if options.ignorePerformanceIndexes {
            object.indexes.removeAll { $0.kind == .nonclustered && !$0.isUnique }
        }
        for index in object.indexes.indices {
            object.indexes[index].options = preparedOptions(object.indexes[index].options,
                                                            isColumnstore: isColumnstore(object.indexes[index].kind))
        }
        if var table = object.table {
            prepare(&table)
            object.table = table
        }
        return object
    }

    private func prepare(_ table: inout TableDefinition) {
        for index in table.columns.indices {
            var column = table.columns[index]
            if options.ignoreCollations {
                column.collation = nil
            } else if column.collation == nil, !column.isComputed, SchemaTypes.isCharacter(column.dataType),
                      !column.isUserDefinedType, !defaultCollation.isEmpty {
                column.collation = defaultCollation
            }
            if options.ignoreDynamicDataMasking { column.maskingFunction = nil }
            if options.ignoreBindings {
                column.boundRule = nil
                column.boundDefault = nil
            }
            column.dataType = SchemaTypes.canonical(column.dataType)
            table.columns[index] = column
        }
        if var key = table.primaryKey {
            key.options = preparedOptions(key.options, isColumnstore: false)
            table.primaryKey = key
        }
        for index in table.uniqueConstraints.indices {
            table.uniqueConstraints[index].options = preparedOptions(table.uniqueConstraints[index].options,
                                                                     isColumnstore: false)
        }
        if options.ignoreCheckConstraints { table.checkConstraints = [] }
        if options.ignoreForeignKeys { table.foreignKeys = [] }
        if options.ignoreFullTextIndexing { table.fullTextIndex = nil }
        if options.ignoreTableLockEscalation { table.lockEscalation = "TABLE" }
        if options.ignoreChangeTracking {
            table.changeTracking = false
            table.changeTrackingColumnsUpdated = false
        }
        if options.ignoreDataCompression { table.dataCompression = "NONE" }
        if table.textImageDataSpace == nil, !table.isMemoryOptimized,
                  table.columns.contains(where: { SchemaTypes.isLargeObject($0.dataType) && !$0.isComputed }) {
            // SQL Server always records a LOB filegroup for tables with LOB columns, whether or
            // not TEXTIMAGE_ON was written.
            table.textImageDataSpace = table.dataSpace.isEmpty ? nil : "PRIMARY"
        }
    }

    private func isColumnstore(_ kind: IndexKind) -> Bool {
        kind == .clusteredColumnstore || kind == .nonclusteredColumnstore
    }

    private func preparedOptions(_ input: IndexOptions, isColumnstore: Bool) -> IndexOptions {
        var value = input
        if options.ignoreFillFactorAndIndexPadding {
            value.fillFactor = 0
            value.padIndex = false
        }
        if options.ignoreLockProperties {
            value.allowRowLocks = true
            value.allowPageLocks = true
        }
        if options.ignoreDataCompression {
            value.dataCompression = isColumnstore ? "COLUMNSTORE" : "NONE"
        }
        return value
    }

    // MARK: - Fingerprint

    /// Canonical text of an already prepared object. Equal fingerprints mean "identical".
    public func fingerprint(_ prepared: SchemaObject, as key: SchemaObjectKey) -> String {
        var object = prepared
        object.schema = key.schema.lowercased()
        object.name = key.name.lowercased()
        object.references = []
        object.owner = object.owner?.lowercased()
        object.roleMemberships = object.roleMemberships.map { $0.lowercased() }.sorted()
        object.permissions = object.permissions.map { permission in
            var copy = permission
            copy.grantee = permission.grantee.lowercased()
            copy.permission = permission.permission.uppercased()
            copy.column = permission.column?.lowercased()
            return copy
        }.sorted()
        object.extendedProperties = object.extendedProperties.map { property in
            var copy = property
            copy.childName = property.childName?.lowercased()
            copy.childType = property.childType?.uppercased()
            return copy
        }.sorted()

        let quotedName = key.type == .ddlTrigger ? SQLIdentifier.quote(key.name) : key.quotedName
        if object.type.isModule || object.type == .function || object.type == .storedProcedure {
            if object.isEncrypted {
                object.body = "<encrypted>"
            } else {
                object.body = ModuleText.comparable(object.body, normalization: options.normalization,
                                                    canonicalName: quotedName)
            }
        } else if object.type != .table && object.type != .schema && object.type != .role {
            object.body = catalogBodyForm(object)
        }
        if options.ignoreQuotedIdentifierAndAnsiNulls || object.type.isModule == false {
            object.usesAnsiNulls = true
            object.usesQuotedIdentifier = true
        }
        if options.ignoreWithEncryption { object.isEncrypted = false }

        object.triggers = object.triggers.map { trigger in
            var copy = trigger
            copy.name = trigger.name.lowercased()
            let target = key.quotedName
            let text = ModuleText.rewrite(trigger.definition, verb: "CREATE",
                                          quotedName: SQLIdentifier.quote(schema: key.schema, name: trigger.name),
                                          triggerTarget: target)
            copy.definition = ModuleText.comparable(text, normalization: options.normalization)
            if options.ignoreQuotedIdentifierAndAnsiNulls {
                copy.usesAnsiNulls = true
                copy.usesQuotedIdentifier = true
            }
            return copy
        }.sorted { $0.name < $1.name }

        object.statistics = object.statistics.map { statistic in
            var copy = statistic
            copy.name = statistic.name.lowercased()
            copy.columns = statistic.columns.map { $0.lowercased() }
            copy.filter = statistic.filter.map(ModuleText.expression)
            return copy
        }.sorted { $0.name < $1.name }

        object.indexes = object.indexes.map { fingerprintIndex($0) }
            .sorted { indexSortKey($0) < indexSortKey($1) }

        if var table = object.table {
            fingerprintTable(&table)
            object.table = table
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(object) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    /// Catalog-built CREATE statements are generated by the reader, so only token-level
    /// normalisation is needed; a few types need their semantics trimmed by option.
    private func catalogBodyForm(_ object: SchemaObject) -> String {
        var body = object.body
        if object.type == .synonym, options.ignoreSynonymDatabaseAndServerNames {
            let tokens = TSQLLexer().significantTokens(body)
            if let forIndex = tokens.firstIndex(where: { $0.text.uppercased() == "FOR" }) {
                let (parts, _, _) = ModuleText.readName(tokens, from: forIndex + 1)
                let kept = parts.suffix(2)
                body = "CREATE SYNONYM \(object.quotedName) FOR "
                    + kept.map(SQLIdentifier.quote).joined(separator: ".")
            }
        }
        if object.type == .sequence, options.ignoreSequenceStartValue {
            body = body.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("START WITH") }
                .joined(separator: "\n")
        }
        let normalization = ModuleText.Normalization(ignoreWhitespace: true, ignoreComments: true,
                                                     caseSensitive: false, ignoreBrackets: true)
        return ModuleText.comparable(body, normalization: normalization)
    }

    private func fingerprintIndex(_ input: IndexDefinition) -> IndexDefinition {
        var index = input
        index.name = options.ignoreConstraintAndIndexNames ? "" : index.name.lowercased()
        index.columns = index.columns.map { IndexColumn(name: $0.name.lowercased(), isDescending: $0.isDescending) }
        index.includedColumns = index.includedColumns.map { $0.lowercased() }.sorted()
        index.filter = index.filter.map(ModuleText.expression)
        index.partitionColumn = options.ignoreFileGroups ? nil : index.partitionColumn?.lowercased()
        index.dataSpace = options.ignoreFileGroups ? "" : index.dataSpace.lowercased()
        index.primaryXmlIndex = options.ignoreConstraintAndIndexNames ? nil : index.primaryXmlIndex?.lowercased()
        index.options.fillFactor = index.options.effectiveFillFactor
        return index
    }

    private func indexSortKey(_ index: IndexDefinition) -> String {
        let columns: [String] = index.columns.map { column in
            column.name + (column.isDescending ? "-" : "+")
        }
        let parts: [String] = [index.name, index.kind.rawValue, columns.joined(separator: ","),
                               index.includedColumns.joined(separator: ","), index.filter ?? ""]
        return parts.joined(separator: "|")
    }

    static func sortKey(_ key: KeyConstraintDefinition) -> String {
        let columns: [String] = key.columns.map(\.name)
        return key.name + "|" + columns.joined(separator: ",")
    }

    static func sortKey(_ check: CheckConstraintDefinition) -> String {
        check.name + "|" + check.definition
    }

    static func sortKey(_ key: ForeignKeyDefinition) -> String {
        let columns: String = key.columns.joined(separator: ",")
        return key.name + "|" + columns + "|" + key.referencedTable
    }

    private func fingerprintKey(_ input: KeyConstraintDefinition) -> KeyConstraintDefinition {
        var key = input
        key.name = constraintName(key.name, isSystemNamed: key.isSystemNamed)
        key.isSystemNamed = false
        key.columns = key.columns.map { IndexColumn(name: $0.name.lowercased(), isDescending: $0.isDescending) }
        key.options.fillFactor = key.options.effectiveFillFactor
        key.dataSpace = options.ignoreFileGroups ? "" : key.dataSpace.lowercased()
        key.partitionColumn = options.ignoreFileGroups ? nil : key.partitionColumn?.lowercased()
        return key
    }

    private func constraintName(_ name: String, isSystemNamed: Bool) -> String {
        if options.ignoreConstraintAndIndexNames { return "" }
        if isSystemNamed && options.ignoreSystemNamedConstraintNames { return "" }
        return name.lowercased()
    }

    private func fingerprintTable(_ table: inout TableDefinition) {
        table.columns = table.columns.map { input in
            var column = input
            column.name = column.name.lowercased()
            column.dataType = SchemaTypes.canonical(column.dataType).lowercased()
            column.collation = column.collation?.lowercased()
            if var identity = column.identity {
                if options.ignoreIdentitySeedAndIncrement {
                    identity.seed = "1"
                    identity.increment = "1"
                } else {
                    identity.seed = Self.number(identity.seed)
                    identity.increment = Self.number(identity.increment)
                }
                if options.ignoreNotForReplication { identity.notForReplication = false }
                column.identity = identity
            }
            if options.ignoreIdentityProperty { column.identity = nil }
            column.computedExpression = column.computedExpression.map(ModuleText.expression)
            if var constraint = column.defaultConstraint {
                constraint.name = constraintName(constraint.name, isSystemNamed: constraint.isSystemNamed)
                constraint.isSystemNamed = false
                constraint.definition = ModuleText.expression(constraint.definition)
                column.defaultConstraint = constraint
            }
            if options.ignoreSparseAndColumnSets {
                column.isSparse = false
                column.isColumnSet = false
            }
            column.boundRule = column.boundRule?.lowercased()
            column.boundDefault = column.boundDefault?.lowercased()
            return column
        }
        if !options.forceColumnOrder {
            table.columns.sort { $0.name < $1.name }
        }
        table.primaryKey = table.primaryKey.map(fingerprintKey)
        table.uniqueConstraints = table.uniqueConstraints.map(fingerprintKey)
            .sorted { Self.sortKey($0) < Self.sortKey($1) }
        table.checkConstraints = table.checkConstraints.map { input in
            var check = input
            check.name = constraintName(check.name, isSystemNamed: check.isSystemNamed)
            check.isSystemNamed = false
            check.definition = ModuleText.expression(check.definition)
            if options.ignoreWithNoCheck {
                check.isNotTrusted = false
                check.isDisabled = false
            }
            if options.ignoreNotForReplication { check.isNotForReplication = false }
            return check
        }.sorted { Self.sortKey($0) < Self.sortKey($1) }
        table.foreignKeys = table.foreignKeys.map { input in
            var key = input
            key.name = constraintName(key.name, isSystemNamed: key.isSystemNamed)
            key.isSystemNamed = false
            key.columns = key.columns.map { $0.lowercased() }
            key.referencedColumns = key.referencedColumns.map { $0.lowercased() }
            key.referencedSchema = key.referencedSchema.lowercased()
            key.referencedTable = key.referencedTable.lowercased()
            key.deleteAction = key.deleteAction.uppercased()
            key.updateAction = key.updateAction.uppercased()
            if options.ignoreWithNoCheck {
                key.isNotTrusted = false
                key.isDisabled = false
            }
            if options.ignoreNotForReplication { key.isNotForReplication = false }
            return key
        }.sorted { Self.sortKey($0) < Self.sortKey($1) }
        table.dataSpace = options.ignoreFileGroups ? "" : table.dataSpace.lowercased()
        table.textImageDataSpace = options.ignoreFileGroups ? nil : table.textImageDataSpace?.lowercased()
        table.partitionColumn = options.ignoreFileGroups ? nil : table.partitionColumn?.lowercased()
        table.lockEscalation = table.lockEscalation.uppercased()
        table.dataCompression = table.dataCompression.uppercased()
        if var temporal = table.temporal {
            temporal.periodStartColumn = temporal.periodStartColumn.lowercased()
            temporal.periodEndColumn = temporal.periodEndColumn.lowercased()
            temporal.historySchema = temporal.historySchema?.lowercased()
            temporal.historyTable = temporal.historyTable?.lowercased()
            table.temporal = temporal
        }
        if var fullText = table.fullTextIndex {
            fullText.catalog = fullText.catalog.lowercased()
            fullText.keyIndex = options.ignoreConstraintAndIndexNames ? "" : fullText.keyIndex.lowercased()
            fullText.columns = fullText.columns.map {
                FullTextIndexColumn(name: $0.name.lowercased(), typeColumn: $0.typeColumn?.lowercased(),
                                    language: $0.language)
            }.sorted { $0.name < $1.name }
            fullText.stoplist = fullText.stoplist?.lowercased()
            table.fullTextIndex = fullText
        }
    }

    /// "1", "1.0" and "0001" all mean one; seeds come back as numeric(38,0) text.
    static func number(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Decimal(string: trimmed) { return "\(value)" }
        return trimmed
    }
}
