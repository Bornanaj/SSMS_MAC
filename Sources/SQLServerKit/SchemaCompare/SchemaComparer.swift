import Foundation

// MARK: - Results

public enum DifferenceStatus: String, Codable, CaseIterable, Sendable {
    case different
    case onlyInSource
    case onlyInTarget
    case identical

    public var title: String {
        switch self {
        case .different: return "Objects that exist in both but differ"
        case .onlyInSource: return "Objects that exist only in the source"
        case .onlyInTarget: return "Objects that exist only in the target"
        case .identical: return "Identical objects"
        }
    }

    public var shortTitle: String {
        switch self {
        case .different: return "Different"
        case .onlyInSource: return "Only in source"
        case .onlyInTarget: return "Only in target"
        case .identical: return "Identical"
        }
    }

    /// The glyph between the two names in the results list.
    public var symbol: String {
        switch self {
        case .different: return "≠"
        case .onlyInSource: return "→"
        case .onlyInTarget: return "←"
        case .identical: return "="
        }
    }
}

/// One row of the comparison results.
public struct SchemaDifference: Identifiable, Sendable, Hashable {
    public var id: String
    public var type: SchemaObjectType
    public var status: DifferenceStatus
    /// The source object, renamed into the target's namespace and prepared under the options.
    public var source: SchemaObject?
    /// The target object, prepared under the options.
    public var target: SchemaObject?
    /// Name of the object in the source database, before owner mapping.
    public var sourceKey: SchemaObjectKey?
    public var targetKey: SchemaObjectKey?
    public var sourceScript: String
    public var targetScript: String
    /// Human-readable list of what differs, e.g. "Column [Name]: nvarchar(50) → nvarchar(100)".
    public var details: [String]
    /// Ticked for deployment. Differences start ticked, identical objects do not.
    public var isSelected: Bool

    public var displayName: String {
        (sourceKey ?? targetKey)?.qualifiedName ?? id
    }

    public var sourceName: String { sourceKey?.qualifiedName ?? "" }
    public var targetName: String { targetKey?.qualifiedName ?? "" }

    /// The key an action in the target database acts on.
    public var deploymentKey: SchemaObjectKey {
        source?.key ?? target?.key ?? SchemaObjectKey(type: type, schema: "", name: id)
    }
}

/// The outcome of comparing two snapshots.
public struct SchemaComparison: Sendable {
    public var source: SchemaSnapshot
    public var target: SchemaSnapshot
    public var options: SchemaCompareOptions
    public var filter: SchemaFilter
    public var mappings: SchemaMappings
    public var differences: [SchemaDifference]
    public var comparedAt: Date

    public func count(_ status: DifferenceStatus) -> Int {
        differences.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
    }

    public var hasDifferences: Bool {
        differences.contains { $0.status != .identical }
    }

    public var selected: [SchemaDifference] {
        differences.filter { $0.isSelected && $0.status != .identical }
    }
}

// MARK: - Comparer

public struct SchemaComparer: Sendable {
    public var options: SchemaCompareOptions
    public var filter: SchemaFilter
    public var mappings: SchemaMappings

    public init(options: SchemaCompareOptions = SchemaCompareOptions(), filter: SchemaFilter = SchemaFilter(),
                mappings: SchemaMappings = SchemaMappings()) {
        self.options = options
        self.filter = filter
        self.mappings = mappings
    }

    public func compare(source: SchemaSnapshot, target: SchemaSnapshot) -> SchemaComparison {
        let sourceNormalizer = SchemaNormalizer(options: options, defaultCollation: source.defaultCollation)
        let targetNormalizer = SchemaNormalizer(options: options, defaultCollation: target.defaultCollation)
        let writer = SchemaScriptWriter(options: SchemaScriptWriter.Options(includeStorage: !options.ignoreFileGroups))

        let sourceObjects = source.objects.filter { include($0.key, sourceSide: true) }
        var targetByKey: [String: SchemaObject] = [:]
        for object in target.objects where include(object.key, sourceSide: false) {
            targetByKey[object.key.matchKey] = object
        }

        var differences: [SchemaDifference] = []
        var matchedTargets: Set<String> = []

        for original in sourceObjects {
            let explicit = mappings.explicitTarget(for: original.key)
            let lookupKey = explicit ?? SchemaObjectKey(type: original.type,
                                                        schema: original.type.isSchemaScoped
                                                            ? mappings.targetSchema(for: original.schema)
                                                            : original.schema,
                                                        name: original.name)
            let targetObject = targetByKey[lookupKey.matchKey]
            // With renaming off, the source is scripted under the target's name so the mapped
            // pair compares equal and deployment alters the target in place.
            let deployName: SchemaObjectKey
            if explicit != nil, let targetObject, !options.renameMappedObjects {
                deployName = targetObject.key
            } else {
                deployName = SchemaObjectKey(type: original.type, schema: lookupKey.schema, name: original.name)
            }
            let mapped = rename(original, to: deployName)
            let preparedSource = sourceNormalizer.prepared(mapped)

            guard let targetObject else {
                differences.append(SchemaDifference(
                    id: "S:" + original.key.matchKey, type: original.type, status: .onlyInSource,
                    source: preparedSource, target: nil, sourceKey: original.key, targetKey: nil,
                    sourceScript: writer.script(for: preparedSource), targetScript: "",
                    details: ["Exists only in the source."], isSelected: true))
                continue
            }
            matchedTargets.insert(targetObject.key.matchKey)
            let preparedTarget = targetNormalizer.prepared(targetObject)
            let sourcePrint = sourceNormalizer.fingerprint(preparedSource, as: deployName)
            // The target is fingerprinted under the deployment name too, so a mapped pair only
            // differs by name when renaming is on.
            let targetPrint = targetNormalizer.fingerprint(preparedTarget,
                                                           as: options.renameMappedObjects ? targetObject.key : deployName)
            let identical = sourcePrint == targetPrint
            var details: [String] = []
            if !identical {
                details = SchemaDifferenceDescriber(options: options)
                    .describe(source: preparedSource, target: preparedTarget,
                              columnMap: columnMap(for: original.key, target: targetObject.key))
                if details.isEmpty { details = ["Definitions differ."] }
            }
            let displayTarget = options.forceColumnOrder ? preparedTarget
                : alignColumns(preparedTarget, like: preparedSource)
            differences.append(SchemaDifference(
                id: "B:" + original.key.matchKey, type: original.type,
                status: identical ? .identical : .different,
                source: preparedSource, target: preparedTarget,
                sourceKey: original.key, targetKey: targetObject.key,
                sourceScript: writer.script(for: preparedSource),
                targetScript: writer.script(for: displayTarget),
                details: details, isSelected: !identical))
        }

        for object in target.objects where include(object.key, sourceSide: false) {
            guard !matchedTargets.contains(object.key.matchKey) else { continue }
            let prepared = targetNormalizer.prepared(object)
            differences.append(SchemaDifference(
                id: "T:" + object.key.matchKey, type: object.type, status: .onlyInTarget,
                source: nil, target: prepared, sourceKey: nil, targetKey: object.key,
                sourceScript: "", targetScript: writer.script(for: prepared),
                details: ["Exists only in the target."], isSelected: true))
        }

        differences.sort { lhs, rhs in
            if lhs.type != rhs.type { return lhs.type < rhs.type }
            return lhs.displayName.lowercased() < rhs.displayName.lowercased()
        }
        return SchemaComparison(source: source, target: target, options: options, filter: filter,
                                mappings: mappings, differences: differences, comparedAt: Date())
    }

    private func include(_ key: SchemaObjectKey, sourceSide: Bool) -> Bool {
        if options.ignoreFileGroups, key.type == .partitionFunction || key.type == .partitionScheme {
            return false
        }
        if sourceSide { return filter.includes(key) }
        // Filter rules are written against source names; translate owner-mapped schemas back.
        let sourceEquivalent = SchemaObjectKey(type: key.type,
                                               schema: key.type.isSchemaScoped
                                                   ? mappings.sourceSchema(for: key.schema) : key.schema,
                                               name: key.name)
        return filter.includes(sourceEquivalent)
    }

    public func columnMap(for source: SchemaObjectKey, target: SchemaObjectKey) -> [String: String] {
        mappings.columnMap(source: source, target: target)
    }

    /// Move an object into the target namespace: new schema/name, owner-mapped references,
    /// and the name inside catalog-built CREATE text.
    func rename(_ object: SchemaObject, to key: SchemaObjectKey) -> SchemaObject {
        var copy = object
        let oldQuoted = object.quotedName
        copy.schema = key.schema
        copy.name = key.name
        if !object.type.isModule, object.type != .table, !copy.body.isEmpty, oldQuoted != copy.quotedName,
           let range = copy.body.range(of: oldQuoted) {
            copy.body.replaceSubrange(range, with: copy.quotedName)
        }
        guard !mappings.schemaMappings.isEmpty else { return copy }
        if var table = copy.table {
            table.foreignKeys = table.foreignKeys.map { key in
                var mapped = key
                mapped.referencedSchema = mappings.targetSchema(for: key.referencedSchema)
                return mapped
            }
            if var temporal = table.temporal, let history = temporal.historySchema {
                temporal.historySchema = mappings.targetSchema(for: history)
                table.temporal = temporal
            }
            copy.table = table
        }
        copy.references = copy.references.map { reference in
            guard reference.type.isSchemaScoped else {
                if reference.type == .schema {
                    return SchemaObjectKey(type: .schema, schema: "", name: mappings.targetSchema(for: reference.name))
                }
                return reference
            }
            return SchemaObjectKey(type: reference.type, schema: mappings.targetSchema(for: reference.schema),
                                   name: reference.name)
        }
        return copy
    }

    /// Show the target's columns in the source's order when order is not being compared, so
    /// the side-by-side view lines up.
    private func alignColumns(_ target: SchemaObject, like source: SchemaObject) -> SchemaObject {
        guard var table = target.table, let sourceTable = source.table else { return target }
        var position: [String: Int] = [:]
        for (offset, column) in sourceTable.columns.enumerated() { position[column.name.lowercased()] = offset }
        let indexed = table.columns.enumerated().map { ($0.offset, $0.element) }
        table.columns = indexed.sorted { lhs, rhs in
            let left = position[lhs.1.name.lowercased()] ?? (10_000 + lhs.0)
            let right = position[rhs.1.name.lowercased()] ?? (10_000 + rhs.0)
            return left < right
        }.map(\.1)
        var copy = target
        copy.table = table
        return copy
    }
}

// MARK: - Describing differences

/// Turns a pair of prepared objects into the short list shown under "Summary".
public struct SchemaDifferenceDescriber: Sendable {
    public let options: SchemaCompareOptions

    public init(options: SchemaCompareOptions) {
        self.options = options
    }

    public func describe(source: SchemaObject, target: SchemaObject, columnMap: [String: String]) -> [String] {
        var lines: [String] = []
        if source.name != target.name || source.schema.lowercased() != target.schema.lowercased() {
            lines.append("Name: \(target.qualifiedName) → \(source.qualifiedName)")
        }
        if let s = source.table, let t = target.table {
            lines.append(contentsOf: describeTable(s, t, columnMap: columnMap))
        } else if source.type.isModule || source.type == .function || source.type == .storedProcedure {
            if source.isEncrypted || target.isEncrypted {
                lines.append("Encrypted: the definition cannot be compared.")
            } else {
                let normalization = options.normalization
                let a = ModuleText.comparable(source.body, normalization: normalization, canonicalName: source.quotedName)
                let b = ModuleText.comparable(target.body, normalization: normalization, canonicalName: source.quotedName)
                if a != b { lines.append("Definition differs.") }
            }
            if source.functionFamily != target.functionFamily, source.type == .function {
                lines.append("Function kind changes; it has to be dropped and re-created.")
            }
            if !options.ignoreQuotedIdentifierAndAnsiNulls,
               source.usesQuotedIdentifier != target.usesQuotedIdentifier
                || source.usesAnsiNulls != target.usesAnsiNulls {
                lines.append("SET QUOTED_IDENTIFIER / ANSI_NULLS settings differ.")
            }
        } else if source.type != .schema && source.type != .role {
            let normalization = ModuleText.Normalization()
            if ModuleText.comparable(source.body, normalization: normalization)
                != ModuleText.comparable(target.body, normalization: normalization) {
                lines.append("Definition differs.")
            }
        }
        lines.append(contentsOf: describeSubObjects(source, target))
        if (source.owner ?? "").lowercased() != (target.owner ?? "").lowercased() {
            lines.append("Owner: \(target.owner ?? "(schema owner)") → \(source.owner ?? "(schema owner)")")
        }
        let addedRoles = Set(source.roleMemberships.map { $0.lowercased() })
            .subtracting(target.roleMemberships.map { $0.lowercased() })
        let removedRoles = Set(target.roleMemberships.map { $0.lowercased() })
            .subtracting(source.roleMemberships.map { $0.lowercased() })
        for role in addedRoles.sorted() { lines.append("Role membership added: \(role)") }
        for role in removedRoles.sorted() { lines.append("Role membership removed: \(role)") }
        lines.append(contentsOf: describePermissions(source.permissions, target.permissions))
        lines.append(contentsOf: describeProperties(source.extendedProperties, target.extendedProperties))
        return lines
    }

    private func describeTable(_ source: TableDefinition, _ target: TableDefinition,
                               columnMap: [String: String]) -> [String] {
        var lines: [String] = []
        let renamedTargets = Set(columnMap.values.map { $0.lowercased() })
        for column in source.columns {
            let targetName = columnMap[column.name.lowercased()] ?? column.name
            guard let other = target.column(named: targetName) else {
                lines.append("Column \(SQLIdentifier.quote(column.name)) added: \(column.dataType)")
                continue
            }
            if other.name.caseInsensitiveCompare(column.name) != .orderedSame {
                lines.append("Column \(SQLIdentifier.quote(other.name)) renamed to \(SQLIdentifier.quote(column.name))")
            }
            lines.append(contentsOf: describeColumn(column, other))
        }
        for column in target.columns {
            let lower = column.name.lowercased()
            let inSource = source.column(named: column.name) != nil || renamedTargets.contains(lower)
            if !inSource { lines.append("Column \(SQLIdentifier.quote(column.name)) dropped") }
        }
        if options.forceColumnOrder {
            let sourceOrder = source.columns.map { $0.name.lowercased() }
            let targetOrder = target.columns.map { columnMapInverse(columnMap)[$0.name.lowercased()] ?? $0.name.lowercased() }
                .filter { sourceOrder.contains($0) }
            if sourceOrder.filter({ targetOrder.contains($0) }) != targetOrder {
                lines.append("Column order differs.")
            }
        }
        if !sameKey(source.primaryKey, target.primaryKey) {
            lines.append(keyChange("Primary key", source.primaryKey, target.primaryKey))
        }
        lines.append(contentsOf: describeNamed("Unique constraint", source.uniqueConstraints.map { ($0.name, keySignature($0)) },
                                               target.uniqueConstraints.map { ($0.name, keySignature($0)) }))
        lines.append(contentsOf: describeNamed("Check constraint",
                                               source.checkConstraints.map { ($0.name, checkSignature($0)) },
                                               target.checkConstraints.map { ($0.name, checkSignature($0)) }))
        lines.append(contentsOf: describeNamed("Foreign key", source.foreignKeys.map { ($0.name, foreignKeySignature($0)) },
                                               target.foreignKeys.map { ($0.name, foreignKeySignature($0)) }))
        if !options.ignoreFileGroups, source.dataSpace.lowercased() != target.dataSpace.lowercased() {
            lines.append("Storage: \(target.dataSpace) → \(source.dataSpace)")
        }
        if source.lockEscalation.uppercased() != target.lockEscalation.uppercased() {
            lines.append("Lock escalation: \(target.lockEscalation) → \(source.lockEscalation)")
        }
        if source.dataCompression.uppercased() != target.dataCompression.uppercased() {
            lines.append("Data compression: \(target.dataCompression) → \(source.dataCompression)")
        }
        if source.changeTracking != target.changeTracking {
            lines.append("Change tracking: \(target.changeTracking ? "on" : "off") → \(source.changeTracking ? "on" : "off")")
        }
        if source.temporal != target.temporal {
            lines.append("System versioning differs.")
        }
        if source.fullTextIndex != target.fullTextIndex {
            lines.append("Full-text index differs.")
        }
        if source.isMemoryOptimized != target.isMemoryOptimized {
            lines.append("Memory-optimized setting differs.")
        }
        return lines
    }

    private func columnMapInverse(_ map: [String: String]) -> [String: String] {
        var inverse: [String: String] = [:]
        for (source, target) in map { inverse[target.lowercased()] = source }
        return inverse
    }

    private func describeColumn(_ source: ColumnDefinition, _ target: ColumnDefinition) -> [String] {
        var lines: [String] = []
        let name = SQLIdentifier.quote(source.name)
        if let s = source.computedExpression, let t = target.computedExpression {
            if ModuleText.expression(s) != ModuleText.expression(t) || source.isPersisted != target.isPersisted {
                lines.append("Column \(name): computed expression \(t) → \(s)")
            }
            return lines
        }
        if (source.computedExpression == nil) != (target.computedExpression == nil) {
            lines.append("Column \(name): computed column status changes")
            return lines
        }
        if SchemaTypes.canonical(source.dataType).lowercased() != SchemaTypes.canonical(target.dataType).lowercased() {
            lines.append("Column \(name): \(target.dataType) → \(source.dataType)")
        }
        if source.isNullable != target.isNullable {
            lines.append("Column \(name): \(target.isNullable ? "NULL" : "NOT NULL") → \(source.isNullable ? "NULL" : "NOT NULL")")
        }
        if (source.collation ?? "").lowercased() != (target.collation ?? "").lowercased() {
            lines.append("Column \(name): collation \(target.collation ?? "default") → \(source.collation ?? "default")")
        }
        if !options.ignoreIdentityProperty, (source.identity == nil) != (target.identity == nil) {
            lines.append("Column \(name): identity \(target.identity == nil ? "off" : "on") → \(source.identity == nil ? "off" : "on")")
        } else if let s = source.identity, let t = target.identity, !options.ignoreIdentitySeedAndIncrement,
                  SchemaNormalizer.number(s.seed) != SchemaNormalizer.number(t.seed)
                    || SchemaNormalizer.number(s.increment) != SchemaNormalizer.number(t.increment) {
            lines.append("Column \(name): IDENTITY(\(t.seed), \(t.increment)) → IDENTITY(\(s.seed), \(s.increment))")
        }
        let sourceDefault = source.defaultConstraint.map { ModuleText.expression($0.definition) }
        let targetDefault = target.defaultConstraint.map { ModuleText.expression($0.definition) }
        if sourceDefault != targetDefault {
            lines.append("Column \(name): default \(target.defaultConstraint?.definition ?? "none") → "
                         + "\(source.defaultConstraint?.definition ?? "none")")
        } else if let s = source.defaultConstraint, let t = target.defaultConstraint,
                  constraintNamesDiffer(s.name, s.isSystemNamed, t.name, t.isSystemNamed) {
            lines.append("Column \(name): default constraint name \(t.name) → \(s.name)")
        }
        if source.isSparse != target.isSparse, !options.ignoreSparseAndColumnSets {
            lines.append("Column \(name): SPARSE \(target.isSparse ? "on" : "off") → \(source.isSparse ? "on" : "off")")
        }
        if source.isRowGuidCol != target.isRowGuidCol { lines.append("Column \(name): ROWGUIDCOL changes") }
        if source.maskingFunction != target.maskingFunction { lines.append("Column \(name): masking function changes") }
        if source.isFileStream != target.isFileStream { lines.append("Column \(name): FILESTREAM changes") }
        if source.boundRule != target.boundRule || source.boundDefault != target.boundDefault {
            lines.append("Column \(name): rule or default binding changes")
        }
        return lines
    }

    private func constraintNamesDiffer(_ a: String, _ aSystem: Bool, _ b: String, _ bSystem: Bool) -> Bool {
        if options.ignoreConstraintAndIndexNames { return false }
        if options.ignoreSystemNamedConstraintNames && (aSystem || bSystem) { return aSystem != bSystem }
        return a.lowercased() != b.lowercased()
    }

    private func sameKey(_ a: KeyConstraintDefinition?, _ b: KeyConstraintDefinition?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            return keySignature(x) == keySignature(y)
                && !constraintNamesDiffer(x.name, x.isSystemNamed, y.name, y.isSystemNamed)
        default: return false
        }
    }

    private func keyChange(_ label: String, _ source: KeyConstraintDefinition?, _ target: KeyConstraintDefinition?) -> String {
        switch (source, target) {
        case (nil, let t?): return "\(label) \(SQLIdentifier.quote(t.name)) dropped"
        case (let s?, nil): return "\(label) \(SQLIdentifier.quote(s.name)) added"
        case let (s?, t?):
            if keySignature(s) == keySignature(t) {
                return "\(label) renamed: \(t.name) → \(s.name)"
            }
            return "\(label) \(SQLIdentifier.quote(s.name)) changes"
        default: return label
        }
    }

    private func keySignature(_ key: KeyConstraintDefinition) -> String {
        let columns: [String] = key.columns.map { column in
            column.name.lowercased() + (column.isDescending ? "-" : "+")
        }
        let indexOptions: IndexOptions = key.options
        var parts: [String] = [String(key.isPrimaryKey), String(key.isClustered)]
        parts.append(columns.joined(separator: ","))
        parts.append(String(indexOptions.effectiveFillFactor))
        parts.append(String(indexOptions.padIndex))
        parts.append(String(indexOptions.ignoreDupKey))
        parts.append(String(indexOptions.allowRowLocks))
        parts.append(String(indexOptions.allowPageLocks))
        parts.append(indexOptions.dataCompression)
        if !options.ignoreFileGroups { parts.append(key.dataSpace.lowercased()) }
        return parts.joined(separator: "|")
    }

    private func checkSignature(_ check: CheckConstraintDefinition) -> String {
        var text = ModuleText.expression(check.definition)
        if !options.ignoreWithNoCheck { text += "|\(check.isNotTrusted)|\(check.isDisabled)" }
        if !options.ignoreNotForReplication { text += "|\(check.isNotForReplication)" }
        return text
    }

    private func foreignKeySignature(_ key: ForeignKeyDefinition) -> String {
        let columns: String = key.columns.joined(separator: ",").lowercased()
        let referenced: String = "\(key.referencedSchema).\(key.referencedTable)".lowercased()
        let referencedColumns: String = key.referencedColumns.joined(separator: ",").lowercased()
        var parts: [String] = [columns, referenced, referencedColumns]
        parts.append(key.deleteAction.uppercased())
        parts.append(key.updateAction.uppercased())
        if !options.ignoreWithNoCheck {
            parts.append(String(key.isNotTrusted))
            parts.append(String(key.isDisabled))
        }
        if !options.ignoreNotForReplication { parts.append(String(key.isNotForReplication)) }
        return parts.joined(separator: "|")
    }

    private func describeNamed(_ label: String, _ source: [(String, String)], _ target: [(String, String)]) -> [String] {
        var lines: [String] = []
        if options.ignoreConstraintAndIndexNames {
            let sourceSet = Set(source.map(\.1))
            let targetSet = Set(target.map(\.1))
            for item in source where !targetSet.contains(item.1) { lines.append("\(label) \(SQLIdentifier.quote(item.0)) added") }
            for item in target where !sourceSet.contains(item.1) { lines.append("\(label) \(SQLIdentifier.quote(item.0)) dropped") }
            return lines
        }
        var targetByName: [String: String] = [:]
        for item in target { targetByName[item.0.lowercased()] = item.1 }
        var bySignature: [String: String] = [:]
        for item in target { bySignature[item.1] = item.0 }
        var seen: Set<String> = []
        for item in source {
            if let signature = targetByName[item.0.lowercased()] {
                seen.insert(item.0.lowercased())
                if signature != item.1 { lines.append("\(label) \(SQLIdentifier.quote(item.0)) changes") }
            } else if let renamed = bySignature[item.1], options.ignoreSystemNamedConstraintNames {
                seen.insert(renamed.lowercased())
                lines.append("\(label) renamed: \(renamed) → \(item.0)")
            } else {
                lines.append("\(label) \(SQLIdentifier.quote(item.0)) added")
            }
        }
        for item in target where !seen.contains(item.0.lowercased()) {
            lines.append("\(label) \(SQLIdentifier.quote(item.0)) dropped")
        }
        return lines
    }

    private func describeSubObjects(_ source: SchemaObject, _ target: SchemaObject) -> [String] {
        var lines: [String] = []
        let sourceIndexes = source.indexes.map { ($0.name, indexSignature($0)) }
        let targetIndexes = target.indexes.map { ($0.name, indexSignature($0)) }
        lines.append(contentsOf: describeNamed("Index", sourceIndexes, targetIndexes))
        let normalization = options.normalization
        let sourceTriggers: [(String, String)] = source.triggers.map { trigger in
            (trigger.name, triggerSignature(trigger, normalization: normalization))
        }
        let targetTriggers: [(String, String)] = target.triggers.map { trigger in
            (trigger.name, triggerSignature(trigger, normalization: normalization))
        }
        lines.append(contentsOf: describeNamedStrict("Trigger", sourceTriggers, targetTriggers))
        let sourceStats: [(String, String)] = source.statistics.map { ($0.name, statisticsSignature($0)) }
        let targetStats: [(String, String)] = target.statistics.map { ($0.name, statisticsSignature($0)) }
        lines.append(contentsOf: describeNamedStrict("Statistics", sourceStats, targetStats))
        return lines
    }

    private func triggerSignature(_ trigger: TriggerDefinition,
                                  normalization: ModuleText.Normalization) -> String {
        let text: String = ModuleText.comparable(trigger.definition, normalization: normalization,
                                                 canonicalName: SQLIdentifier.quote(trigger.name))
        let order: String = trigger.order.keys.sorted().map { "\($0)=\(trigger.order[$0] ?? "")" }
            .joined(separator: ",")
        return [text, String(trigger.isDisabled), order].joined(separator: "|")
    }

    private func statisticsSignature(_ statistic: StatisticsDefinition) -> String {
        let columns: String = statistic.columns.map { $0.lowercased() }.joined(separator: ",")
        let filter: String = statistic.filter.map(ModuleText.expression) ?? ""
        return [columns, filter, String(statistic.noRecompute)].joined(separator: "|")
    }

    /// Like `describeNamed` but always matched by name (triggers and statistics are named
    /// objects even when constraint names are ignored).
    private func describeNamedStrict(_ label: String, _ source: [(String, String)], _ target: [(String, String)]) -> [String] {
        var lines: [String] = []
        var targetByName: [String: String] = [:]
        for item in target { targetByName[item.0.lowercased()] = item.1 }
        let sourceNames = Set(source.map { $0.0.lowercased() })
        for item in source {
            if let signature = targetByName[item.0.lowercased()] {
                if signature != item.1 { lines.append("\(label) \(SQLIdentifier.quote(item.0)) changes") }
            } else {
                lines.append("\(label) \(SQLIdentifier.quote(item.0)) added")
            }
        }
        for item in target where !sourceNames.contains(item.0.lowercased()) {
            lines.append("\(label) \(SQLIdentifier.quote(item.0)) dropped")
        }
        return lines
    }

    private func indexSignature(_ index: IndexDefinition) -> String {
        let columns: [String] = index.columns.map { column in
            column.name.lowercased() + (column.isDescending ? "-" : "+")
        }
        let included: [String] = index.includedColumns.map { $0.lowercased() }.sorted()
        let filter: String = index.filter.map(ModuleText.expression) ?? ""
        let indexOptions: IndexOptions = index.options
        var parts: [String] = [index.kind.rawValue, String(index.isUnique)]
        parts.append(columns.joined(separator: ","))
        parts.append(included.joined(separator: ","))
        parts.append(filter)
        parts.append(String(indexOptions.effectiveFillFactor))
        parts.append(String(indexOptions.padIndex))
        parts.append(String(indexOptions.ignoreDupKey))
        parts.append(String(indexOptions.allowRowLocks))
        parts.append(String(indexOptions.allowPageLocks))
        parts.append(String(indexOptions.statisticsNoRecompute))
        parts.append(indexOptions.dataCompression)
        if !options.ignoreFileGroups { parts.append(index.dataSpace.lowercased()) }
        parts.append(String(index.isDisabled))
        return parts.joined(separator: "|")
    }

    private func describePermissions(_ source: [PermissionDefinition], _ target: [PermissionDefinition]) -> [String] {
        var lines: [String] = []
        var targetSlots: [String: PermissionDefinition] = [:]
        for permission in target { targetSlots[permission.slotKey] = permission }
        var sourceSlots: Set<String> = []
        for permission in source {
            sourceSlots.insert(permission.slotKey)
            let label = "\(permission.permission.uppercased()) for \(SQLIdentifier.quote(permission.grantee))"
                + (permission.column.map { " on column \(SQLIdentifier.quote($0))" } ?? "")
            if let existing = targetSlots[permission.slotKey] {
                if existing.state.uppercased() != permission.state.uppercased() {
                    lines.append("Permission \(label): \(existing.state) → \(permission.state)")
                }
            } else {
                lines.append("Permission added: \(permission.state) \(label)")
            }
        }
        for permission in target where !sourceSlots.contains(permission.slotKey) {
            lines.append("Permission removed: \(permission.state) \(permission.permission.uppercased()) for "
                         + SQLIdentifier.quote(permission.grantee))
        }
        return lines
    }

    private func describeProperties(_ source: [ExtendedPropertyDefinition],
                                    _ target: [ExtendedPropertyDefinition]) -> [String] {
        var lines: [String] = []
        var targetSlots: [String: ExtendedPropertyDefinition] = [:]
        for property in target { targetSlots[property.slotKey] = property }
        var seen: Set<String> = []
        for property in source {
            seen.insert(property.slotKey)
            let label = property.name + (property.childName.map { " on \(property.childType?.lowercased() ?? "") \($0)" } ?? "")
            if let existing = targetSlots[property.slotKey] {
                if existing.value != property.value { lines.append("Extended property \(label) changes") }
            } else {
                lines.append("Extended property \(label) added")
            }
        }
        for property in target where !seen.contains(property.slotKey) {
            let label = property.name + (property.childName.map { " on \(property.childType?.lowercased() ?? "") \($0)" } ?? "")
            lines.append("Extended property \(label) removed")
        }
        return lines
    }
}
