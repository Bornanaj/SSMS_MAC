import Foundation

/// The statements that turn one existing table into the desired one.
struct TableChangeSet {
    var rebuild = false
    var rebuildReasons: [String] = []
    var mainBatches: [String] = []
    var postBatches: [String] = []
    var preTransactionBatches: [String] = []
    var postTransactionBatches: [String] = []
    var warnings: [DeploymentWarning] = []
    /// Lowercased names of existing columns that are altered or dropped.
    var affectedColumns: Set<String> = []
    /// Column sets (lowercased) of primary keys, unique constraints and unique indexes that are
    /// dropped and re-created, so foreign keys pointing at them can be handled.
    var recreatedKeys: [Set<String>] = []
    /// Existing columns are altered, dropped or renamed, which schema-bound dependents block.
    var touchesExistingColumns = false
}

/// Plans ALTER TABLE statements, falling back to a rebuild through a copy of the table when a
/// change cannot be made in place — an identity added to a column, a forced column order, a
/// move to another filegroup.
///
/// Foreign keys are not handled here: the deployment planner drops and re-adds them globally,
/// because an FK belongs to one table but depends on another.
struct TableAlterPlanner {
    let options: SchemaCompareOptions
    let writer: SchemaScriptWriter
    /// Resolves a user-defined type name (lowercased `schema.name`) to its base type text.
    let baseTypeOf: (String) -> String?

    // MARK: - New tables

    func createPlan(_ desired: SchemaObject) -> TableChangeSet {
        var result = TableChangeSet()
        guard let table = desired.table else { return result }
        let target = desired.quotedName
        var create = writer.createTableStatement(desired, name: target)
        if options.addObjectExistenceChecks {
            create = "IF OBJECT_ID(N'\(escape(target))', N'U') IS NULL\n" + create
        }
        result.mainBatches.append(create)
        result.mainBatches.append(contentsOf: writer.tablePostCreateBatches(desired, table: table, target: target,
                                                                           includeFullText: false))
        result.mainBatches.append(contentsOf: securityBatches(desired, previous: nil))
        if let fullText = table.fullTextIndex {
            result.postTransactionBatches.append(writer.createFullTextIndexStatement(fullText, table: target))
        }
        return result
    }

    // MARK: - Existing tables

    func plan(desired: SchemaObject, actual: SchemaObject, columnMap: [String: String]) -> TableChangeSet {
        guard let want = desired.table, let have = actual.table else { return TableChangeSet() }
        let target = desired.quotedName
        let pairing = pairColumns(want, have, columnMap: columnMap)

        var reasons: [String] = []
        for pair in pairing.pairs where identityRequiresRebuild(pair.desired, pair.actual) {
            reasons.append("the identity property of column \(SQLIdentifier.quote(pair.desired.name)) changes")
        }
        for pair in pairing.pairs where pair.desired.isFileStream != pair.actual.isFileStream {
            reasons.append("FILESTREAM changes on column \(SQLIdentifier.quote(pair.desired.name))")
        }
        for pair in pairing.pairs where pair.desired.isColumnSet != pair.actual.isColumnSet
            && !options.ignoreSparseAndColumnSets {
            reasons.append("the column set \(SQLIdentifier.quote(pair.desired.name)) changes")
        }
        if options.forceColumnOrder, columnOrderRequiresRebuild(want, pairing) {
            reasons.append("the column order changes")
        }
        if !options.ignoreFileGroups, want.dataSpace.lowercased() != have.dataSpace.lowercased(),
           !want.isMemoryOptimized {
            reasons.append("the table moves from \(have.dataSpace) to \(want.dataSpace)")
        }
        if want.isMemoryOptimized != have.isMemoryOptimized {
            reasons.append("the memory-optimized setting changes")
        }
        if !reasons.isEmpty {
            return rebuildPlan(desired: desired, actual: actual, pairing: pairing, reasons: reasons)
        }
        return alterPlan(desired: desired, actual: actual, pairing: pairing, target: target)
    }

    // MARK: - Column pairing

    struct ColumnPair {
        var desired: ColumnDefinition
        var actual: ColumnDefinition
    }

    struct Pairing {
        var pairs: [ColumnPair] = []
        var added: [ColumnDefinition] = []
        var dropped: [ColumnDefinition] = []
    }

    private func pairColumns(_ want: TableDefinition, _ have: TableDefinition,
                             columnMap: [String: String]) -> Pairing {
        var result = Pairing()
        var used: Set<String> = []
        for column in want.columns {
            let mapped = columnMap[column.name.lowercased()] ?? column.name
            if let existing = have.column(named: mapped), !used.contains(existing.name.lowercased()) {
                var desired = column
                if !options.renameMappedObjects { desired.name = existing.name }
                result.pairs.append(ColumnPair(desired: desired, actual: existing))
                used.insert(existing.name.lowercased())
            } else {
                result.added.append(column)
            }
        }
        result.dropped = have.columns.filter { !used.contains($0.name.lowercased()) }
        return result
    }

    private func columnOrderRequiresRebuild(_ want: TableDefinition, _ pairing: Pairing) -> Bool {
        // After an in-place alter the surviving columns keep their order and new ones go last.
        let droppedNames = Set(pairing.dropped.map { $0.name.lowercased() })
        let pairedByActual: [String: String] = Dictionary(
            pairing.pairs.map { ($0.actual.name.lowercased(), $0.desired.name.lowercased()) },
            uniquingKeysWith: { first, _ in first })
        var result: [String] = []
        for column in pairing.pairs.map(\.actual).sorted(by: { lhs, rhs in
            actualPosition(lhs, pairing) < actualPosition(rhs, pairing)
        }) where !droppedNames.contains(column.name.lowercased()) {
            result.append(pairedByActual[column.name.lowercased()] ?? column.name.lowercased())
        }
        result.append(contentsOf: pairing.added.map { $0.name.lowercased() })
        return result != want.columns.map { $0.name.lowercased() }
    }

    private func actualPosition(_ column: ColumnDefinition, _ pairing: Pairing) -> Int {
        let all = pairing.pairs.map(\.actual) + pairing.dropped
        return all.firstIndex { $0.name.caseInsensitiveCompare(column.name) == .orderedSame } ?? Int.max
    }

    // MARK: - Comparisons under the options

    private func identityRequiresRebuild(_ desired: ColumnDefinition, _ actual: ColumnDefinition) -> Bool {
        if options.ignoreIdentityProperty { return false }
        switch (desired.identity, actual.identity) {
        case (nil, nil): return false
        case let (a?, b?):
            if options.ignoreIdentitySeedAndIncrement { return false }
            return SchemaNormalizer.number(a.seed) != SchemaNormalizer.number(b.seed)
                || SchemaNormalizer.number(a.increment) != SchemaNormalizer.number(b.increment)
        default: return true
        }
    }

    private func needsAlterColumn(_ desired: ColumnDefinition, _ actual: ColumnDefinition) -> Bool {
        if desired.isComputed || actual.isComputed { return false }
        if SchemaTypes.canonical(desired.dataType).lowercased() != SchemaTypes.canonical(actual.dataType).lowercased() {
            return true
        }
        if desired.isNullable != actual.isNullable { return true }
        if let a = desired.collation, let b = actual.collation, a.lowercased() != b.lowercased() { return true }
        if !options.ignoreSparseAndColumnSets, desired.isSparse != actual.isSparse { return true }
        return false
    }

    private func computedChanges(_ desired: ColumnDefinition, _ actual: ColumnDefinition) -> Bool {
        guard desired.isComputed || actual.isComputed else { return false }
        guard let a = desired.computedExpression, let b = actual.computedExpression else { return true }
        return ModuleText.expression(a) != ModuleText.expression(b)
            || desired.isPersisted != actual.isPersisted
            || (desired.isPersisted && desired.isNullable != actual.isNullable)
    }

    private func namesEquivalent(_ a: String, _ aSystem: Bool, _ b: String, _ bSystem: Bool) -> Bool {
        if options.ignoreConstraintAndIndexNames { return true }
        if options.ignoreSystemNamedConstraintNames && aSystem && bSystem { return true }
        return a.lowercased() == b.lowercased()
    }

    private func keySignature(_ key: KeyConstraintDefinition) -> String {
        let columns: [String] = key.columns.map { $0.name.lowercased() + ($0.isDescending ? "-" : "+") }
        var parts: [String] = [String(key.isPrimaryKey), String(key.isClustered), columns.joined(separator: ",")]
        parts.append(indexOptionSignature(key.options))
        if !options.ignoreFileGroups {
            parts.append(key.dataSpace.lowercased())
            parts.append(key.partitionColumn?.lowercased() ?? "")
        }
        return parts.joined(separator: "|")
    }

    private func indexOptionSignature(_ value: IndexOptions) -> String {
        let parts: [String] = [String(value.effectiveFillFactor), String(value.padIndex), String(value.ignoreDupKey),
                               String(value.allowRowLocks), String(value.allowPageLocks),
                               String(value.statisticsNoRecompute), value.dataCompression.uppercased(),
                               String(value.optimizeForSequentialKey)]
        return parts.joined(separator: ",")
    }

    private func indexSignature(_ index: IndexDefinition) -> String {
        let columns: [String] = index.columns.map { $0.name.lowercased() + ($0.isDescending ? "-" : "+") }
        let included: [String] = index.includedColumns.map { $0.lowercased() }.sorted()
        var parts: [String] = [index.kind.rawValue, String(index.isUnique), columns.joined(separator: ","),
                               included.joined(separator: ",")]
        parts.append(index.filter.map(ModuleText.expression) ?? "")
        parts.append(indexOptionSignature(index.options))
        if !options.ignoreFileGroups { parts.append(index.dataSpace.lowercased()) }
        parts.append(index.primaryXmlIndex?.lowercased() ?? "")
        parts.append(index.secondaryXmlType?.uppercased() ?? "")
        parts.append(index.spatialTessellation?.uppercased() ?? "")
        parts.append(index.spatialBoundingBox ?? "")
        return parts.joined(separator: "|")
    }

    private func checkSignature(_ check: CheckConstraintDefinition) -> String {
        var parts: [String] = [ModuleText.expression(check.definition)]
        if !options.ignoreNotForReplication { parts.append(String(check.isNotForReplication)) }
        if !options.ignoreWithNoCheck {
            parts.append(String(check.isNotTrusted))
            parts.append(String(check.isDisabled))
        }
        return parts.joined(separator: "|")
    }

    private func statisticsSignature(_ statistic: StatisticsDefinition) -> String {
        let columns: String = statistic.columns.map { $0.lowercased() }.joined(separator: ",")
        return [columns, statistic.filter.map(ModuleText.expression) ?? "", String(statistic.noRecompute)]
            .joined(separator: "|")
    }

    private func triggerSignature(_ trigger: TriggerDefinition, schema: String) -> String {
        let text = ModuleText.comparable(trigger.definition, normalization: options.normalization,
                                         canonicalName: SQLIdentifier.quote(schema: schema, name: trigger.name))
        var parts: [String] = [text]
        if !options.ignoreQuotedIdentifierAndAnsiNulls {
            parts.append(String(trigger.usesQuotedIdentifier))
            parts.append(String(trigger.usesAnsiNulls))
        }
        return parts.joined(separator: "|")
    }

    /// Pairs named children. Equal names pair up; with names ignored (all of them, or the
    /// generated ones) the leftovers pair by signature.
    private func match<T>(_ desired: [T], _ actual: [T], name: (T) -> String, isSystemNamed: (T) -> Bool,
                          signature: (T) -> String) -> (pairs: [(T, T)], added: [T], removed: [T]) {
        var pairs: [(T, T)] = []
        var remainingActual = actual
        var added: [T] = []
        var unmatchedDesired: [T] = []
        if !options.ignoreConstraintAndIndexNames {
            for item in desired {
                if let index = remainingActual.firstIndex(where: {
                    name($0).lowercased() == name(item).lowercased() && !name(item).isEmpty
                }) {
                    pairs.append((item, remainingActual.remove(at: index)))
                } else {
                    unmatchedDesired.append(item)
                }
            }
        } else {
            unmatchedDesired = desired
        }
        for item in unmatchedDesired {
            let byName = options.ignoreConstraintAndIndexNames
                || (options.ignoreSystemNamedConstraintNames && isSystemNamed(item))
            if byName, let index = remainingActual.firstIndex(where: {
                signature($0) == signature(item)
                    && (options.ignoreConstraintAndIndexNames || isSystemNamed($0))
            }) {
                pairs.append((item, remainingActual.remove(at: index)))
            } else {
                added.append(item)
            }
        }
        return (pairs, added, remainingActual)
    }

    // MARK: - In-place alter

    private func alterPlan(desired: SchemaObject, actual: SchemaObject, pairing: Pairing,
                           target: String) -> TableChangeSet {
        var result = TableChangeSet()
        guard let want = desired.table, let have = actual.table else { return result }
        let tableName = desired.qualifiedName

        // Which existing columns change in a way that blocks dependent objects.
        var altered: [ColumnPair] = []
        var computedDropAdd: [ColumnPair] = []
        var renamed: [ColumnPair] = []
        for pair in pairing.pairs {
            if pair.desired.name != pair.actual.name { renamed.append(pair) }
            if computedChanges(pair.desired, pair.actual) {
                computedDropAdd.append(pair)
            } else if needsAlterColumn(pair.desired, pair.actual) {
                altered.append(pair)
            }
        }
        var affected: Set<String> = Set(altered.map { $0.actual.name.lowercased() })
        affected.formUnion(pairing.dropped.map { $0.name.lowercased() })
        affected.formUnion(computedDropAdd.map { $0.actual.name.lowercased() })
        // Computed columns built on an affected column have to be dropped and added back.
        var changed = true
        while changed {
            changed = false
            for pair in pairing.pairs where pair.actual.isComputed && !affected.contains(pair.actual.name.lowercased()) {
                if let expression = pair.actual.computedExpression, references(expression, affected) {
                    computedDropAdd.append(pair)
                    affected.insert(pair.actual.name.lowercased())
                    changed = true
                }
            }
        }
        result.affectedColumns = affected
        result.touchesExistingColumns = !affected.isEmpty || !renamed.isEmpty

        var drops: [String] = []
        var adds: [String] = []

        // Temporal tables cannot be altered while system versioning is on.
        let versioningOn = have.temporal?.isSystemVersioned ?? false
        let wantVersioning = want.temporal?.isSystemVersioned ?? false
        let temporalChanges = have.temporal != want.temporal
        let needsVersioningOff = versioningOn && (temporalChanges || !affected.isEmpty
                                                  || !pairing.added.isEmpty || !renamed.isEmpty)
        if needsVersioningOff {
            drops.append("ALTER TABLE \(target) SET (SYSTEM_VERSIONING = OFF)")
        }

        // Triggers.
        let triggers = match(desired.triggers, actual.triggers, name: { $0.name }, isSystemNamed: { _ in false },
                             signature: { triggerSignature($0, schema: desired.schema) })
        var triggerBatches: [String] = []
        for trigger in triggers.removed {
            drops.append("DROP TRIGGER \(SQLIdentifier.quote(schema: actual.schema, name: trigger.name))")
        }
        for (wanted, existing) in triggers.pairs {
            let quoted = SQLIdentifier.quote(schema: desired.schema, name: wanted.name)
            if triggerSignature(wanted, schema: desired.schema) != triggerSignature(existing, schema: desired.schema) {
                if options.dropAndCreateInsteadOfAlter {
                    drops.append("DROP TRIGGER \(SQLIdentifier.quote(schema: actual.schema, name: existing.name))")
                    triggerBatches.append(contentsOf: writer.triggerBatches(wanted, schema: desired.schema, target: target))
                } else {
                    triggerBatches.append(contentsOf: alterTriggerBatches(wanted, schema: desired.schema, target: target))
                }
            } else {
                if wanted.isDisabled != existing.isDisabled {
                    triggerBatches.append("\(wanted.isDisabled ? "DISABLE" : "ENABLE") TRIGGER \(quoted) ON \(target)")
                }
                if wanted.order != existing.order {
                    triggerBatches.append(contentsOf: triggerOrderBatches(wanted, quoted: quoted, previous: existing))
                }
            }
        }
        for trigger in triggers.added {
            triggerBatches.append(contentsOf: writer.triggerBatches(trigger, schema: desired.schema, target: target))
        }

        // Full-text index: dropped before the transaction when it changes or covers a column
        // that is about to change, created again after it.
        let fullTextColumns = Set((have.fullTextIndex?.columns ?? []).map { $0.name.lowercased() })
        let fullTextChanges = want.fullTextIndex != have.fullTextIndex
            || !fullTextColumns.isDisjoint(with: affected)
        if fullTextChanges {
            if have.fullTextIndex != nil {
                result.preTransactionBatches.append("DROP FULLTEXT INDEX ON \(target)")
            }
            if let fullText = want.fullTextIndex {
                result.postTransactionBatches.append(writer.createFullTextIndexStatement(fullText, table: target))
            }
        }

        // Statistics.
        let statistics = match(desired.statistics, actual.statistics, name: { $0.name }, isSystemNamed: { _ in false },
                               signature: statisticsSignature)
        var statisticsAdds: [String] = []
        for statistic in statistics.removed {
            drops.append("DROP STATISTICS \(target).\(SQLIdentifier.quote(statistic.name))")
        }
        for (wanted, existing) in statistics.pairs {
            let touches = !Set(existing.columns.map { $0.lowercased() }).isDisjoint(with: affected)
            if statisticsSignature(wanted) != statisticsSignature(existing) || touches {
                drops.append("DROP STATISTICS \(target).\(SQLIdentifier.quote(existing.name))")
                statisticsAdds.append(writer.createStatisticsStatement(wanted, on: target))
            }
        }
        statisticsAdds.append(contentsOf: statistics.added.map { writer.createStatisticsStatement($0, on: target) })

        // Indexes.
        let indexes = match(desired.indexes, actual.indexes, name: { $0.name }, isSystemNamed: { _ in false },
                            signature: indexSignature)
        var indexDrops: [IndexDefinition] = indexes.removed
        var indexAdds: [IndexDefinition] = indexes.added
        var indexStateBatches: [String] = []
        for (wanted, existing) in indexes.pairs {
            let columns = Set((existing.columns.map(\.name) + existing.includedColumns).map { $0.lowercased() })
            let filterTouches = existing.filter.map { references($0, affected) } ?? false
            let touches = !columns.isDisjoint(with: affected) || filterTouches
            if indexSignature(wanted) != indexSignature(existing) || touches {
                indexDrops.append(existing)
                indexAdds.append(wanted)
            } else if wanted.isDisabled != existing.isDisabled {
                indexStateBatches.append("ALTER INDEX \(SQLIdentifier.quote(wanted.name)) ON \(target) "
                                         + (wanted.isDisabled ? "DISABLE" : "REBUILD"))
            } else if wanted.name != existing.name, !options.ignoreConstraintAndIndexNames {
                indexStateBatches.append(renameIndexStatement(target: target, from: existing.name, to: wanted.name))
            }
        }
        // Renames: an index that only changed its name keeps its data.
        (indexDrops, indexAdds) = extractIndexRenames(drops: indexDrops, adds: indexAdds, target: target,
                                                      into: &indexStateBatches)
        for index in indexDrops.sorted(by: dropOrder) {
            drops.append(writer.dropIndexStatement(name: index.name, on: target))
            if index.isUnique || index.kind == .clustered {
                result.recreatedKeys.append(Set(index.columns.map { $0.name.lowercased() }))
            }
        }

        // Check constraints.
        let checks = match(want.checkConstraints, have.checkConstraints, name: { $0.name },
                           isSystemNamed: { $0.isSystemNamed }, signature: checkSignature)
        var checkAdds: [CheckConstraintDefinition] = checks.added
        var checkDrops: [CheckConstraintDefinition] = checks.removed
        for (wanted, existing) in checks.pairs {
            if checkSignature(wanted) != checkSignature(existing) || references(existing.definition, affected)
                || !namesEquivalent(wanted.name, wanted.isSystemNamed, existing.name, existing.isSystemNamed) {
                checkDrops.append(existing)
                checkAdds.append(wanted)
            }
        }
        for check in checkDrops { drops.append(writer.dropConstraintStatement(name: check.name, table: target)) }

        // Unique constraints and the primary key.
        let uniques = match(want.uniqueConstraints, have.uniqueConstraints, name: { $0.name },
                            isSystemNamed: { $0.isSystemNamed }, signature: keySignature)
        var uniqueAdds: [KeyConstraintDefinition] = uniques.added
        var uniqueDrops: [KeyConstraintDefinition] = uniques.removed
        for (wanted, existing) in uniques.pairs {
            let touches = !Set(existing.columns.map { $0.name.lowercased() }).isDisjoint(with: affected)
            if keySignature(wanted) != keySignature(existing) || touches
                || !namesEquivalent(wanted.name, wanted.isSystemNamed, existing.name, existing.isSystemNamed) {
                uniqueDrops.append(existing)
                uniqueAdds.append(wanted)
            }
        }
        var primaryKeyDrop: KeyConstraintDefinition?
        var primaryKeyAdd: KeyConstraintDefinition?
        switch (want.primaryKey, have.primaryKey) {
        case let (wanted?, existing?):
            let touches = !Set(existing.columns.map { $0.name.lowercased() }).isDisjoint(with: affected)
            if keySignature(wanted) != keySignature(existing) || touches
                || !namesEquivalent(wanted.name, wanted.isSystemNamed, existing.name, existing.isSystemNamed) {
                primaryKeyDrop = existing
                primaryKeyAdd = wanted
            }
        case (let wanted?, nil): primaryKeyAdd = wanted
        case (nil, let existing?): primaryKeyDrop = existing
        default: break
        }
        for key in uniqueDrops {
            drops.append(writer.dropConstraintStatement(name: key.name, table: target))
            result.recreatedKeys.append(Set(key.columns.map { $0.name.lowercased() }))
        }
        if let key = primaryKeyDrop {
            drops.append(writer.dropConstraintStatement(name: key.name, table: target))
            result.recreatedKeys.append(Set(key.columns.map { $0.name.lowercased() }))
        }

        // Defaults on existing columns.
        var defaultAdds: [(DefaultConstraintDefinition, String)] = []
        let computedNames = Set(computedDropAdd.map { $0.actual.name.lowercased() })
        for pair in pairing.pairs where !computedNames.contains(pair.actual.name.lowercased()) {
            let wanted = pair.desired.defaultConstraint
            let existing = pair.actual.defaultConstraint
            let isAffected = affected.contains(pair.actual.name.lowercased())
            var differs = false
            switch (wanted, existing) {
            case let (w?, e?):
                differs = ModuleText.expression(w.definition) != ModuleText.expression(e.definition)
                    || !namesEquivalent(w.name, w.isSystemNamed, e.name, e.isSystemNamed)
            case (nil, nil): differs = false
            default: differs = true
            }
            if differs || isAffected {
                if let e = existing { drops.append(writer.dropConstraintStatement(name: e.name, table: target)) }
                if let w = wanted { defaultAdds.append((w, pair.desired.name)) }
            }
        }
        for column in pairing.dropped {
            if let constraint = column.defaultConstraint {
                drops.append(writer.dropConstraintStatement(name: constraint.name, table: target))
            }
        }

        // Bindings.
        var bindingBatches: [String] = []
        for pair in pairing.pairs {
            let columnPath = target + "." + SQLIdentifier.quote(pair.desired.name)
            if pair.actual.boundRule != pair.desired.boundRule {
                if pair.actual.boundRule != nil {
                    drops.append("EXEC sp_unbindrule \(SQLIdentifier.literal(target + "." + SQLIdentifier.quote(pair.actual.name)))")
                }
                if let rule = pair.desired.boundRule {
                    bindingBatches.append("EXEC sp_bindrule \(SQLIdentifier.literal(rule)), \(SQLIdentifier.literal(columnPath))")
                }
            }
            if pair.actual.boundDefault != pair.desired.boundDefault {
                if pair.actual.boundDefault != nil {
                    drops.append("EXEC sp_unbindefault \(SQLIdentifier.literal(target + "." + SQLIdentifier.quote(pair.actual.name)))")
                }
                if let bound = pair.desired.boundDefault {
                    bindingBatches.append("EXEC sp_bindefault \(SQLIdentifier.literal(bound)), \(SQLIdentifier.literal(columnPath))")
                }
            }
        }

        // Column renames.
        var columnBatches: [String] = []
        for pair in renamed {
            let path = target + "." + SQLIdentifier.quote(pair.actual.name)
            columnBatches.append("EXEC sp_rename \(SQLIdentifier.literal(path)), "
                                 + "\(SQLIdentifier.literal(pair.desired.name)), N'COLUMN'")
        }

        // Temporal period removal.
        if let period = have.temporal, want.temporal == nil || want.temporal?.periodStartColumn.lowercased()
            != period.periodStartColumn.lowercased() || want.temporal?.periodEndColumn.lowercased()
            != period.periodEndColumn.lowercased() {
            columnBatches.append("ALTER TABLE \(target) DROP PERIOD FOR SYSTEM_TIME")
        }

        // Dropped columns, including computed columns that are re-added below.
        let dropNames: [String] = pairing.dropped.map(\.name) + computedDropAdd.map(\.actual.name)
        if !dropNames.isEmpty {
            columnBatches.append("ALTER TABLE \(target) DROP COLUMN "
                                 + dropNames.map(SQLIdentifier.quote).joined(separator: ", "))
            for column in pairing.dropped {
                result.warnings.append(DeploymentWarning(
                    severity: .high, object: tableName,
                    message: "Column \(SQLIdentifier.quote(column.name)) is dropped. The data it holds will be lost."))
            }
        }

        // Altered columns.
        for pair in altered {
            let name = SQLIdentifier.quote(pair.desired.name)
            if pair.actual.isNullable && !pair.desired.isNullable {
                if options.addSmartDefaults,
                   let value = pair.desired.defaultConstraint?.definition ?? smartDefault(for: pair.desired.dataType) {
                    columnBatches.append("UPDATE \(target) SET \(name) = \(value) WHERE \(name) IS NULL")
                    result.warnings.append(DeploymentWarning(
                        severity: .medium, object: tableName,
                        message: "Column \(name) becomes NOT NULL. Existing NULLs are set to \(value)."))
                } else {
                    result.warnings.append(DeploymentWarning(
                        severity: .high, object: tableName,
                        message: "Column \(name) becomes NOT NULL. The deployment fails if the column holds NULLs."))
                }
            }
            columnBatches.append("ALTER TABLE \(target) ALTER COLUMN " + alterColumnDefinition(pair.desired))
            if let warning = typeChangeWarning(pair, table: tableName) { result.warnings.append(warning) }
        }
        for pair in pairing.pairs where !computedNames.contains(pair.actual.name.lowercased()) {
            let name = SQLIdentifier.quote(pair.desired.name)
            if pair.desired.isRowGuidCol != pair.actual.isRowGuidCol {
                columnBatches.append("ALTER TABLE \(target) ALTER COLUMN \(name) "
                                     + (pair.desired.isRowGuidCol ? "ADD" : "DROP") + " ROWGUIDCOL")
            }
            if pair.desired.maskingFunction != pair.actual.maskingFunction {
                if let mask = pair.desired.maskingFunction {
                    if pair.actual.maskingFunction != nil {
                        columnBatches.append("ALTER TABLE \(target) ALTER COLUMN \(name) DROP MASKED")
                    }
                    columnBatches.append("ALTER TABLE \(target) ALTER COLUMN \(name) ADD MASKED WITH "
                                         + "(FUNCTION = '\(mask.replacingOccurrences(of: "'", with: "''"))')")
                } else {
                    columnBatches.append("ALTER TABLE \(target) ALTER COLUMN \(name) DROP MASKED")
                }
            }
            if !options.ignoreNotForReplication, let a = pair.desired.identity, let b = pair.actual.identity,
               a.notForReplication != b.notForReplication {
                columnBatches.append("ALTER TABLE \(target) ALTER COLUMN \(name) "
                                     + (a.notForReplication ? "ADD" : "DROP") + " NOT FOR REPLICATION")
            }
        }

        // New columns, then computed columns that were dropped above.
        var temporaryDefaults: [String] = []
        let periodColumns: Set<String> = Set([want.temporal?.periodStartColumn.lowercased(),
                                              want.temporal?.periodEndColumn.lowercased()].compactMap { $0 })
        let addPeriod = want.temporal != nil && (have.temporal == nil || columnBatches.contains {
            $0.hasSuffix("DROP PERIOD FOR SYSTEM_TIME")
        })
        var periodDefinitions: [String] = []
        for column in pairing.added where !column.isComputed {
            if addPeriod, periodColumns.contains(column.name.lowercased()) {
                periodDefinitions.append(periodColumnDefinition(column))
                continue
            }
            var definition = writer.columnDefinition(column)
            if !column.isNullable, column.defaultConstraint == nil, column.identity == nil {
                if options.addSmartDefaults, let value = smartDefault(for: column.dataType) {
                    let constraint = "DF_SSMS_tmp_\(sanitized(desired.name))_\(sanitized(column.name))"
                    definition += " CONSTRAINT \(SQLIdentifier.quote(constraint)) DEFAULT (\(value))"
                    temporaryDefaults.append(constraint)
                    result.warnings.append(DeploymentWarning(
                        severity: .low, object: tableName,
                        message: "Column \(SQLIdentifier.quote(column.name)) is added as NOT NULL; existing rows "
                        + "get \(value) through a temporary default."))
                } else {
                    result.warnings.append(DeploymentWarning(
                        severity: .high, object: tableName,
                        message: "Column \(SQLIdentifier.quote(column.name)) is added as NOT NULL without a default. "
                        + "The deployment fails if the table contains rows. Allow NULLs, add a default, or turn "
                        + "on smart defaults."))
                }
            }
            columnBatches.append("ALTER TABLE \(target) ADD " + definition)
        }
        if addPeriod, let temporal = want.temporal {
            var parts = periodDefinitions
            parts.append("PERIOD FOR SYSTEM_TIME (\(SQLIdentifier.quote(temporal.periodStartColumn)), "
                         + "\(SQLIdentifier.quote(temporal.periodEndColumn)))")
            columnBatches.append("ALTER TABLE \(target) ADD " + parts.joined(separator: ", "))
        }
        for constraint in temporaryDefaults {
            columnBatches.append(writer.dropConstraintStatement(name: constraint, table: target))
        }
        let computedAdds: [ColumnDefinition] = pairing.added.filter(\.isComputed) + computedDropAdd.map(\.desired)
        for column in computedAdds {
            columnBatches.append("ALTER TABLE \(target) ADD " + writer.columnDefinition(column))
        }

        // With filegroups ignored nothing is placed explicitly, but a unique or clustered key
        // on a partitioned table must contain the partition column; one that does not is put
        // on the default filegroup instead of being aligned.
        let partitionColumn: String? = options.ignoreFileGroups ? have.partitionColumn?.lowercased() : nil
        func placement(_ columns: [IndexColumn], clusteredOrUnique: Bool) -> String? {
            guard let partitionColumn, clusteredOrUnique else { return nil }
            if columns.contains(where: { $0.name.lowercased() == partitionColumn }) { return nil }
            return "[PRIMARY]"
        }

        // Re-adds.
        for (constraint, column) in defaultAdds {
            adds.append(writer.addDefaultStatement(constraint, column: column, table: target))
        }
        adds.append(contentsOf: bindingBatches)
        if let key = primaryKeyAdd {
            adds.append(writer.addKeyConstraintStatement(key, table: target, online: options.addOnlineOption,
                                                         storageOverride: placement(key.columns, clusteredOrUnique: true)))
        }
        for key in uniqueAdds {
            adds.append(writer.addKeyConstraintStatement(key, table: target, online: options.addOnlineOption,
                                                         storageOverride: placement(key.columns, clusteredOrUnique: true)))
        }
        for check in checkAdds { adds.append(contentsOf: writer.checkConstraintBatches(check, table: target)) }
        for index in indexAdds.sorted(by: createOrder) {
            let clusteredOrUnique: Bool = index.isUnique || index.kind == .clustered
            let override: String? = index.kind == .clustered || index.kind == .nonclustered
                ? placement(index.columns, clusteredOrUnique: clusteredOrUnique) : nil
            adds.append(contentsOf: writer.createIndexBatches(index, on: target, online: options.addOnlineOption,
                                                              storageOverride: override))
        }
        adds.append(contentsOf: indexStateBatches)
        adds.append(contentsOf: statisticsAdds)
        adds.append(contentsOf: triggerBatches)

        // Table options.
        if want.lockEscalation.uppercased() != have.lockEscalation.uppercased(), !want.isMemoryOptimized {
            adds.append("ALTER TABLE \(target) SET (LOCK_ESCALATION = \(want.lockEscalation.uppercased()))")
        }
        if want.changeTracking != have.changeTracking {
            adds.append(writer.changeTrackingStatement(target: target, enable: want.changeTracking,
                                                       trackColumns: want.changeTrackingColumnsUpdated))
        } else if want.changeTracking, want.changeTrackingColumnsUpdated != have.changeTrackingColumnsUpdated {
            adds.append(writer.changeTrackingStatement(target: target, enable: false, trackColumns: false))
            adds.append(writer.changeTrackingStatement(target: target, enable: true,
                                                       trackColumns: want.changeTrackingColumnsUpdated))
        }
        if want.dataCompression.uppercased() != have.dataCompression.uppercased(), !options.ignoreDataCompression {
            adds.append("ALTER TABLE \(target) REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = "
                        + "\(want.dataCompression.uppercased()))")
        }
        adds.append(contentsOf: securityBatches(desired, previous: actual))

        if wantVersioning, let temporal = want.temporal, let history = temporal.historyTable,
           needsVersioningOff || !versioningOn {
            let historyName = SQLIdentifier.quote(schema: temporal.historySchema ?? desired.schema, name: history)
            result.postBatches.append("ALTER TABLE \(target) SET (SYSTEM_VERSIONING = ON "
                                      + "(HISTORY_TABLE = \(historyName)))")
        }

        result.mainBatches = drops + columnBatches + adds
        return result
    }

    private func extractIndexRenames(drops: [IndexDefinition], adds: [IndexDefinition], target: String,
                                     into batches: inout [String]) -> ([IndexDefinition], [IndexDefinition]) {
        guard !options.ignoreConstraintAndIndexNames else { return (drops, adds) }
        var remainingDrops = drops
        var remainingAdds: [IndexDefinition] = []
        for add in adds {
            if let index = remainingDrops.firstIndex(where: {
                indexSignature($0) == indexSignature(add) && $0.isDisabled == add.isDisabled
                    && $0.name.lowercased() != add.name.lowercased()
            }) {
                let existing = remainingDrops.remove(at: index)
                batches.append(renameIndexStatement(target: target, from: existing.name, to: add.name))
            } else {
                remainingAdds.append(add)
            }
        }
        return (remainingDrops, remainingAdds)
    }

    private func renameIndexStatement(target: String, from: String, to: String) -> String {
        "EXEC sp_rename \(SQLIdentifier.literal(target + "." + SQLIdentifier.quote(from))), "
            + "\(SQLIdentifier.literal(to)), N'INDEX'"
    }

    private func dropOrder(_ lhs: IndexDefinition, _ rhs: IndexDefinition) -> Bool {
        func rank(_ index: IndexDefinition) -> Int {
            switch index.kind {
            case .secondaryXml: return 0
            case .primaryXml, .spatial, .nonclustered, .nonclusteredColumnstore: return 1
            case .clustered, .clusteredColumnstore: return 2
            }
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        return lhs.name.lowercased() < rhs.name.lowercased()
    }

    private func createOrder(_ lhs: IndexDefinition, _ rhs: IndexDefinition) -> Bool {
        func rank(_ index: IndexDefinition) -> Int {
            switch index.kind {
            case .clustered, .clusteredColumnstore: return 0
            case .nonclustered, .nonclusteredColumnstore, .spatial: return 1
            case .primaryXml: return 2
            case .secondaryXml: return 3
            }
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        return lhs.name.lowercased() < rhs.name.lowercased()
    }

    private func alterTriggerBatches(_ trigger: TriggerDefinition, schema: String, target: String) -> [String] {
        var out: [String] = []
        if writer.options.includeSetOptions {
            out.append("SET QUOTED_IDENTIFIER \(trigger.usesQuotedIdentifier ? "ON" : "OFF")")
            out.append("SET ANSI_NULLS \(trigger.usesAnsiNulls ? "ON" : "OFF")")
        }
        let quoted = SQLIdentifier.quote(schema: schema, name: trigger.name)
        out.append(ModuleText.rewrite(trigger.definition, verb: "ALTER", quotedName: quoted, triggerTarget: target)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("\(trigger.isDisabled ? "DISABLE" : "ENABLE") TRIGGER \(quoted) ON \(target)")
        out.append(contentsOf: triggerOrderBatches(trigger, quoted: quoted, previous: nil))
        return out
    }

    private func triggerOrderBatches(_ trigger: TriggerDefinition, quoted: String,
                                     previous: TriggerDefinition?) -> [String] {
        var out: [String] = []
        var events = Set(trigger.order.keys)
        if let previous { events.formUnion(previous.order.keys) }
        for event in events.sorted() {
            let order = trigger.order[event] ?? "None"
            if previous?.order[event] == trigger.order[event] { continue }
            out.append("EXEC sp_settriggerorder N'\(escape(quoted))', N'\(order)', N'\(event.uppercased())'")
        }
        return out
    }

    // MARK: - Rebuild

    private func rebuildPlan(desired: SchemaObject, actual: SchemaObject, pairing: Pairing,
                             reasons: [String]) -> TableChangeSet {
        var result = TableChangeSet()
        guard let want = desired.table, let have = actual.table else { return result }
        result.rebuild = true
        result.rebuildReasons = reasons
        result.touchesExistingColumns = true
        result.affectedColumns = Set(have.columns.map { $0.name.lowercased() })
        if let key = have.primaryKey { result.recreatedKeys.append(Set(key.columns.map { $0.name.lowercased() })) }
        for key in have.uniqueConstraints { result.recreatedKeys.append(Set(key.columns.map { $0.name.lowercased() })) }
        for index in actual.indexes where index.isUnique {
            result.recreatedKeys.append(Set(index.columns.map { $0.name.lowercased() }))
        }

        let tableName = desired.qualifiedName
        let current = actual.quotedName
        let temporaryName = "SSMS_Rebuild_" + String(desired.name.prefix(100))
        let temporary = SQLIdentifier.quote(schema: desired.schema, name: temporaryName)
        result.warnings.append(DeploymentWarning(
            severity: .medium, object: tableName,
            message: "The table is rebuilt because \(reasons.joined(separator: ", ")). Its data is copied into a "
            + "new table, which can take a long time on a large table."))
        if have.temporal?.isSystemVersioned ?? false {
            result.warnings.append(DeploymentWarning(
                severity: .high, object: tableName,
                message: "The table is system-versioned. System versioning is switched off for the rebuild; "
                + "review the script before running it."))
        }
        for column in pairing.dropped {
            result.warnings.append(DeploymentWarning(
                severity: .high, object: tableName,
                message: "Column \(SQLIdentifier.quote(column.name)) is dropped. The data it holds will be lost."))
        }

        var batches: [String] = []
        if have.temporal?.isSystemVersioned ?? false {
            batches.append("ALTER TABLE \(current) SET (SYSTEM_VERSIONING = OFF)")
        }
        if have.fullTextIndex != nil {
            result.preTransactionBatches.append("DROP FULLTEXT INDEX ON \(current)")
        }
        // Constraint names are schema-wide, so the old table has to give them up first.
        for column in have.columns {
            if let constraint = column.defaultConstraint {
                batches.append(writer.dropConstraintStatement(name: constraint.name, table: current))
            }
        }
        for check in have.checkConstraints { batches.append(writer.dropConstraintStatement(name: check.name, table: current)) }
        for key in have.uniqueConstraints { batches.append(writer.dropConstraintStatement(name: key.name, table: current)) }
        if let key = have.primaryKey { batches.append(writer.dropConstraintStatement(name: key.name, table: current)) }

        var shell = desired
        shell.table?.primaryKey = nil
        shell.table?.uniqueConstraints = []
        shell.table?.checkConstraints = []
        shell.table?.temporal = nil
        shell.table?.foreignKeys = []
        if want.temporal != nil {
            shell.table?.columns = want.columns.map { column in
                var copy = column
                copy.generatedAlways = nil
                copy.isHidden = false
                return copy
            }
        }
        batches.append(writer.createTableStatement(shell, name: temporary))

        // Copy the data.
        var targetColumns: [String] = []
        var sourceExpressions: [String] = []
        var identityInsert = false
        var identityCarried = false
        let pairsByDesired: [String: ColumnPair] = Dictionary(
            pairing.pairs.map { ($0.desired.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for column in want.columns where !column.isComputed && !isRowVersion(column) {
            if let pair = pairsByDesired[column.name.lowercased()], !pair.actual.isComputed, !isRowVersion(pair.actual) {
                targetColumns.append(SQLIdentifier.quote(column.name))
                let sameType = SchemaTypes.canonical(column.dataType).lowercased()
                    == SchemaTypes.canonical(pair.actual.dataType).lowercased()
                var expression = SQLIdentifier.quote(pair.actual.name)
                if !sameType { expression = "CAST(\(expression) AS \(column.dataType))" }
                if pair.actual.isNullable && !column.isNullable {
                    if let value = column.defaultConstraint?.definition ?? smartDefault(for: column.dataType),
                       options.addSmartDefaults {
                        expression = "ISNULL(\(expression), \(value))"
                    }
                }
                sourceExpressions.append(expression)
                if column.identity != nil {
                    identityInsert = true
                    identityCarried = pair.actual.identity != nil
                }
                if !sameType, let warning = typeChangeWarning(pair, table: tableName) {
                    result.warnings.append(warning)
                }
            } else if !column.isNullable, column.defaultConstraint == nil, column.identity == nil {
                if let value = smartDefault(for: column.dataType), options.addSmartDefaults {
                    targetColumns.append(SQLIdentifier.quote(column.name))
                    sourceExpressions.append(value)
                } else {
                    result.warnings.append(DeploymentWarning(
                        severity: .high, object: tableName,
                        message: "New column \(SQLIdentifier.quote(column.name)) is NOT NULL without a default; "
                        + "copying existing rows will fail."))
                }
            }
        }
        if !targetColumns.isEmpty {
            var copy = ""
            if identityInsert { copy += "SET IDENTITY_INSERT \(temporary) ON\n" }
            copy += "INSERT INTO \(temporary) (" + targetColumns.joined(separator: ", ") + ")\n"
            copy += "SELECT " + sourceExpressions.joined(separator: ", ") + " FROM \(current)"
            if identityInsert { copy += "\nSET IDENTITY_INSERT \(temporary) OFF" }
            batches.append(copy)
        }
        if identityCarried {
            batches.append("""
            DECLARE @idVal BIGINT
            SELECT @idVal = IDENT_CURRENT(N'\(escape(current))')
            IF @idVal IS NOT NULL
                DBCC CHECKIDENT(N'\(escape(temporary))', RESEED, @idVal)
            """)
        } else if identityInsert {
            batches.append("DBCC CHECKIDENT(N'\(escape(temporary))', RESEED)")
        }
        batches.append("DROP TABLE \(current)")
        batches.append("EXEC sp_rename \(SQLIdentifier.literal(temporary)), "
                       + "\(SQLIdentifier.literal(desired.name)), N'OBJECT'")

        let target = desired.quotedName
        if let temporal = want.temporal {
            batches.append("ALTER TABLE \(target) ADD PERIOD FOR SYSTEM_TIME ("
                           + "\(SQLIdentifier.quote(temporal.periodStartColumn)), "
                           + "\(SQLIdentifier.quote(temporal.periodEndColumn)))")
        }
        if let key = want.primaryKey { batches.append(writer.addKeyConstraintStatement(key, table: target)) }
        for key in want.uniqueConstraints { batches.append(writer.addKeyConstraintStatement(key, table: target)) }
        for check in want.checkConstraints where !check.isNotTrusted && !check.isDisabled {
            batches.append(contentsOf: writer.checkConstraintBatches(check, table: target))
        }
        batches.append(contentsOf: writer.tablePostCreateBatches(desired, table: want, target: target,
                                                                includeFullText: false))
        batches.append(contentsOf: securityBatches(desired, previous: nil))
        if let fullText = want.fullTextIndex {
            result.postTransactionBatches.append(writer.createFullTextIndexStatement(fullText, table: target))
        }
        if let temporal = want.temporal, let history = temporal.historyTable {
            let historyName = SQLIdentifier.quote(schema: temporal.historySchema ?? desired.schema, name: history)
            result.postBatches.append("ALTER TABLE \(target) SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = \(historyName)))")
        }
        result.mainBatches = batches
        return result
    }

    // MARK: - Security and properties

    /// GRANT/REVOKE and extended property changes. With no previous version everything is added.
    func securityBatches(_ desired: SchemaObject, previous: SchemaObject?) -> [String] {
        var out: [String] = []
        let old = previous?.permissions ?? []
        var oldSlots: [String: PermissionDefinition] = [:]
        for permission in old { oldSlots[permission.slotKey] = permission }
        var newSlots: Set<String> = []
        for permission in desired.permissions {
            newSlots.insert(permission.slotKey)
            if let existing = oldSlots[permission.slotKey] {
                if existing.state.uppercased() != permission.state.uppercased() {
                    if existing.state.uppercased() == "GRANT_WITH_GRANT_OPTION" {
                        out.append(writer.revokeStatement(existing, on: desired))
                    }
                    out.append(writer.permissionStatement(permission, on: desired))
                }
            } else {
                out.append(writer.permissionStatement(permission, on: desired))
            }
        }
        for permission in old where !newSlots.contains(permission.slotKey) {
            out.append(writer.revokeStatement(permission, on: desired))
        }

        let oldProperties = previous?.extendedProperties ?? []
        var oldBySlot: [String: ExtendedPropertyDefinition] = [:]
        for property in oldProperties { oldBySlot[property.slotKey] = property }
        var seen: Set<String> = []
        for property in desired.extendedProperties {
            seen.insert(property.slotKey)
            if let existing = oldBySlot[property.slotKey] {
                if existing.value != property.value {
                    out.append(writer.extendedPropertyStatement(procedure: "sp_updateextendedproperty",
                                                                property: property, on: desired))
                }
            } else {
                out.append(writer.extendedPropertyStatement(procedure: "sp_addextendedproperty",
                                                            property: property, on: desired))
            }
        }
        for property in oldProperties where !seen.contains(property.slotKey) {
            out.append(writer.extendedPropertyStatement(procedure: "sp_dropextendedproperty",
                                                        property: property, on: desired))
        }
        if (desired.owner ?? "").lowercased() != (previous?.owner ?? "").lowercased() {
            if let owner = desired.owner, !owner.isEmpty {
                out.append(writer.authorizationStatement(desired, owner: owner))
            } else if previous != nil {
                out.append("ALTER AUTHORIZATION ON OBJECT::\(desired.quotedName) TO SCHEMA OWNER")
            }
        }
        return out
    }

    // MARK: - Helpers

    private func alterColumnDefinition(_ column: ColumnDefinition) -> String {
        var text = SQLIdentifier.quote(column.name) + " " + column.dataType
        if let collation = column.collation, !collation.isEmpty, SchemaTypes.isCharacter(column.dataType) {
            text += " COLLATE \(collation)"
        }
        if column.isSparse { text += " SPARSE" }
        text += column.isNullable ? " NULL" : " NOT NULL"
        return text
    }

    private func periodColumnDefinition(_ column: ColumnDefinition) -> String {
        var copy = column
        let isStart = (column.generatedAlways ?? "").uppercased().contains("START")
        if copy.defaultConstraint == nil {
            let value = isStart ? "SYSUTCDATETIME()" : "CONVERT(datetime2, '9999-12-31 23:59:59.9999999')"
            copy.defaultConstraint = DefaultConstraintDefinition(name: "", definition: value, isSystemNamed: true)
        }
        return writer.columnDefinition(copy)
    }

    private func isRowVersion(_ column: ColumnDefinition) -> Bool {
        let base = SchemaTypes.baseName(of: column.dataType)
        return base == "timestamp" || base == "rowversion"
    }

    /// True when `expression` mentions any of `columns` (lowercased names).
    func references(_ expression: String, _ columns: Set<String>) -> Bool {
        guard !columns.isEmpty else { return false }
        for token in TSQLLexer().significantTokens(expression) {
            switch token.kind {
            case .identifier, .quotedIdentifier, .keyword, .dataType, .builtInFunction:
                if columns.contains(ModuleText.unquote(token.text).lowercased()) { return true }
            default:
                continue
            }
        }
        return false
    }

    private func typeChangeWarning(_ pair: ColumnPair, table: String) -> DeploymentWarning? {
        let old = SchemaTypes.canonical(pair.actual.dataType).lowercased()
        let new = SchemaTypes.canonical(pair.desired.dataType).lowercased()
        guard old != new else { return nil }
        let name = SQLIdentifier.quote(pair.desired.name)
        let oldBase = SchemaTypes.baseName(of: old)
        let newBase = SchemaTypes.baseName(of: new)
        var narrowing = oldBase != newBase
        if oldBase == newBase {
            if let a = SchemaTypes.length(of: old), let b = SchemaTypes.length(of: new) {
                narrowing = (b != -1) && (a == -1 || b < a)
            } else if let a = SchemaTypes.precisionScale(of: old), let b = SchemaTypes.precisionScale(of: new) {
                narrowing = b.0 < a.0 || b.1 < a.1
            }
        }
        if narrowing {
            return DeploymentWarning(severity: .high, object: table,
                                     message: "Column \(name) changes from \(pair.actual.dataType) to "
                                     + "\(pair.desired.dataType). Values may be truncated or fail to convert.")
        }
        return DeploymentWarning(severity: .low, object: table,
                                 message: "Column \(name) changes from \(pair.actual.dataType) to \(pair.desired.dataType).")
    }

    /// A value every row can take when a NOT NULL column appears or stops allowing NULL.
    func smartDefault(for dataType: String) -> String? {
        var base = SchemaTypes.baseName(of: dataType)
        if base.contains("."), let resolved = baseTypeOf(base) {
            base = SchemaTypes.baseName(of: resolved)
        }
        switch base {
        case "bigint", "int", "smallint", "tinyint", "bit", "decimal", "numeric", "money", "smallmoney",
             "float", "real", "sql_variant":
            return "0"
        case "char", "varchar", "nchar", "nvarchar", "text", "ntext", "sysname":
            return "''"
        case "binary", "varbinary", "image":
            return "0x"
        case "uniqueidentifier":
            return "'00000000-0000-0000-0000-000000000000'"
        case "date", "datetime", "datetime2", "smalldatetime", "datetimeoffset":
            return "'19000101'"
        case "time":
            return "'00:00:00'"
        case "xml":
            return "N''"
        case "hierarchyid":
            return "'/'"
        default:
            return nil
        }
    }

    private func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let characters: [Character] = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(String(characters).prefix(40))
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }
}
