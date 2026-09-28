import Foundation

/// Turns the selected differences of a comparison into an ordered, transactional deployment
/// script, the way the Deployment Wizard does: dependencies are pulled in, objects that stand
/// in the way are dropped and re-created, foreign keys are managed across tables, and every
/// risky step is reported as a warning.
public struct SchemaDeploymentPlanner: Sendable {
    public let comparison: SchemaComparison
    public let targetDatabaseName: String

    public init(comparison: SchemaComparison, targetDatabaseName: String? = nil) {
        self.comparison = comparison
        self.targetDatabaseName = targetDatabaseName ?? comparison.target.databaseName
    }

    var options: SchemaCompareOptions { comparison.options }

    /// - Parameter selectedIDs: difference IDs to deploy; nil uses each difference's
    ///   `isSelected` flag.
    public func plan(selectedIDs: Set<String>? = nil) -> DeploymentPlan {
        var builder = PlanBuilder(comparison: comparison, targetDatabaseName: targetDatabaseName)
        builder.build(selectedIDs: selectedIDs)
        return builder.finish()
    }
}

// MARK: - Builder

private struct PlanBuilder {
    let comparison: SchemaComparison
    let targetDatabaseName: String
    let options: SchemaCompareOptions
    let writer: SchemaScriptWriter
    let tablePlanner: TableAlterPlanner

    /// Desired state of every source object, in the target's namespace.
    var desired: [String: SchemaObject] = [:]
    /// Current state of every target object.
    var actual: [String: SchemaObject] = [:]
    var desiredGraph: [String: Set<String>] = [:]
    var actualGraph: [String: Set<String>] = [:]
    /// matchKey -> keys of objects that reference it, in the target.
    var dependents: [String: [SchemaObjectKey]] = [:]
    var differenceByKey: [String: SchemaDifference] = [:]

    var steps: [DeploymentStep] = []
    var actions: [DeploymentAction] = []
    var warnings: [DeploymentWarning] = []
    var dependencyKeys: [SchemaObjectKey] = []
    var sequence = 0

    /// Target objects that disappear for good.
    var dropped: Set<String> = []
    /// Target objects dropped and created again (by choice or as a cascade).
    var recreated: Set<String> = []
    /// Tables whose definition is handled by this deployment, keyed by desired key.
    var tableChanges: [String: TableChangeSet] = [:]
    var createdTables: Set<String> = []
    var convertedColumns: [String: Set<String>] = [:]
    var convertedKeys: [String: [Set<String>]] = [:]
    /// Differences in the deployment, keyed by deployment key.
    var deploying: [String: SchemaDifference] = [:]

    init(comparison: SchemaComparison, targetDatabaseName: String) {
        self.comparison = comparison
        self.targetDatabaseName = targetDatabaseName
        self.options = comparison.options
        let writer = SchemaScriptWriter(options: SchemaScriptWriter.Options(
            includePermissions: true, includeExtendedProperties: true, includeSetOptions: true,
            includeRoleMemberships: true, includeStorage: !comparison.options.ignoreFileGroups))
        self.writer = writer

        let comparer = SchemaComparer(options: comparison.options, filter: comparison.filter,
                                      mappings: comparison.mappings)
        let sourceNormalizer = SchemaNormalizer(options: comparison.options,
                                                defaultCollation: comparison.source.defaultCollation)
        let targetNormalizer = SchemaNormalizer(options: comparison.options,
                                                defaultCollation: comparison.target.defaultCollation)
        var desiredObjects: [String: SchemaObject] = [:]
        for object in comparison.source.objects {
            let key = SchemaObjectKey(type: object.type,
                                      schema: object.type.isSchemaScoped
                                          ? comparison.mappings.targetSchema(for: object.schema) : object.schema,
                                      name: object.name)
            desiredObjects[key.matchKey] = sourceNormalizer.prepared(comparer.rename(object, to: key))
        }
        for difference in comparison.differences {
            if let source = difference.source { desiredObjects[source.key.matchKey] = source }
        }
        var actualObjects: [String: SchemaObject] = [:]
        for object in comparison.target.objects {
            actualObjects[object.key.matchKey] = targetNormalizer.prepared(object)
        }
        desired = desiredObjects
        actual = actualObjects

        let lookup: [String: SchemaObject] = desiredObjects
        tablePlanner = TableAlterPlanner(options: comparison.options, writer: writer, baseTypeOf: { name in
            let parts = name.split(separator: ".").map(String.init)
            guard parts.count == 2 else { return nil }
            let key = SchemaObjectKey(type: .userDefinedType, schema: parts[0], name: parts[1])
            guard let type = lookup[key.matchKey] else { return nil }
            return PlanBuilder.aliasBaseType(type.body)
        })

        for object in desiredObjects.values {
            desiredGraph[object.key.matchKey] = Set(object.references.map(\.matchKey))
        }
        for object in actualObjects.values {
            actualGraph[object.key.matchKey] = Set(object.references.map(\.matchKey))
            for reference in object.references {
                dependents[reference.matchKey, default: []].append(object.key)
            }
        }
        for difference in comparison.differences {
            differenceByKey[difference.deploymentKey.matchKey] = difference
            if let target = difference.target { differenceByKey[target.key.matchKey] = difference }
        }
    }

    // MARK: - Selection

    mutating func build(selectedIDs: Set<String>?) {
        var chosen: [SchemaDifference] = comparison.differences.filter { difference in
            guard difference.status != .identical else { return false }
            if let selectedIDs { return selectedIDs.contains(difference.id) }
            return difference.isSelected
        }
        var chosenIDs = Set(chosen.map(\.id))

        if options.includeDependencies {
            var queue = chosen
            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard let source = current.source else { continue }
                for key in requirements(of: source) {
                    guard let difference = differenceByKey[key.matchKey],
                          difference.status == .onlyInSource || difference.status == .different,
                          !chosenIDs.contains(difference.id) else { continue }
                    chosenIDs.insert(difference.id)
                    chosen.append(difference)
                    queue.append(difference)
                    dependencyKeys.append(difference.deploymentKey)
                }
            }
        }

        for difference in chosen { deploying[difference.deploymentKey.matchKey] = difference }
        for difference in chosen where difference.status == .onlyInTarget {
            if let target = difference.target { dropped.insert(target.key.matchKey) }
        }

        // Types first, so column conversions are sequenced before the tables' own steps.
        let ordered = chosen.sorted { lhs, rhs in
            if lhs.type != rhs.type { return lhs.type < rhs.type }
            return lhs.displayName.lowercased() < rhs.displayName.lowercased()
        }
        for difference in ordered {
            plan(difference, isDependency: dependencyKeys.contains(difference.deploymentKey))
        }
        planForeignKeys()
        planViewRefreshes()
    }

    /// Everything an object needs to exist before it can be created.
    private func requirements(of object: SchemaObject) -> [SchemaObjectKey] {
        var keys = object.references
        if let table = object.table {
            keys.append(contentsOf: table.foreignKeys.map(\.referencedKey))
            if let temporal = table.temporal, let history = temporal.historyTable {
                keys.append(SchemaObjectKey(type: .table, schema: temporal.historySchema ?? object.schema, name: history))
            }
        }
        return keys
    }

    // MARK: - Per difference

    private mutating func plan(_ difference: SchemaDifference, isDependency: Bool) {
        switch difference.status {
        case .onlyInSource:
            guard let source = difference.source else { return }
            planCreate(source, isDependency: isDependency)
        case .onlyInTarget:
            guard let target = difference.target else { return }
            planDrop(target)
        case .different:
            guard let source = difference.source, let target = difference.target else { return }
            if source.key != target.key {
                planRename(from: target, to: source)
            }
            var renamedTarget = target
            renamedTarget.schema = source.schema
            renamedTarget.name = source.name
            planAlter(source, renamedTarget, originalTarget: target, difference: difference, isDependency: isDependency)
        case .identical:
            return
        }
    }

    private mutating func planCreate(_ object: SchemaObject, isDependency: Bool) {
        if object.isEncrypted {
            warnings.append(DeploymentWarning(severity: .high, object: object.qualifiedName,
                                              message: "The object is encrypted in the source, so it cannot be created."))
            return
        }
        actions.append(DeploymentAction(kind: .create, key: object.key, isDependency: isDependency))
        if object.type == .table {
            let change = tablePlanner.createPlan(object)
            tableChanges[object.key.matchKey] = change
            createdTables.insert(object.key.matchKey)
            addStep(.main, key: object.key, title: "Creating \(label(object))", batches: change.mainBatches)
            addStep(.postTransaction, key: object.key, title: "Creating full-text index on \(label(object))",
                    batches: change.postTransactionBatches)
            return
        }
        let phase: DeploymentPhase = isFullText(object.type) ? .postTransaction : .main
        addStep(phase, key: object.key, title: "Creating \(label(object))", batches: createBatches(object))
        if object.type == .user, object.body.contains("N'<password>'") {
            warnings.append(DeploymentWarning(severity: .medium, object: object.qualifiedName,
                                              message: "The password of a contained user cannot be read from the source. "
                                              + "The user is created with a random password; set it after deployment."))
        }
        if object.type == .applicationRole {
            warnings.append(DeploymentWarning(severity: .medium, object: object.qualifiedName,
                                              message: "Application role passwords cannot be read. The role is created with "
                                              + "a random password; set it after deployment."))
        }
    }

    private mutating func planDrop(_ object: SchemaObject) {
        actions.append(DeploymentAction(kind: .drop, key: object.key))
        // Still used by something that is altered rather than dropped: the alter has to stop
        // using it first.
        let usedByAltered = (dependents[object.key.matchKey] ?? []).contains { dependent in
            guard !dropped.contains(dependent.matchKey) else { return false }
            return deploying.values.contains { $0.status == .different && $0.target?.key == dependent }
        }
        let phase: DeploymentPhase = isFullText(object.type) ? .postTransaction : (usedByAltered ? .lateDrop : .drop)
        addStep(phase, key: object.key, title: "Dropping \(label(object))", batches: dropBatches(object), actualSide: true)
        switch object.type {
        case .table:
            warnings.append(DeploymentWarning(severity: .high, object: object.qualifiedName,
                                              message: "The table is dropped. The data it holds will be lost."))
        case .user, .role, .schema:
            warnings.append(DeploymentWarning(severity: .medium, object: object.qualifiedName,
                                              message: "The \(object.type.title.lowercased()) is dropped."))
        default:
            break
        }
        // Objects that are not being dropped but still need this one.
        for dependent in dependents[object.key.matchKey] ?? [] where !dropped.contains(dependent.matchKey) {
            guard let other = actual[dependent.matchKey] else { continue }
            if other.isSchemaBound || other.type == .securityPolicy {
                cascade(other, because: object)
            } else if other.type.isModule || other.type == .storedProcedure || other.type == .function {
                warnings.append(DeploymentWarning(
                    severity: .medium, object: other.qualifiedName,
                    message: "It references \(object.qualifiedName), which is being dropped, and will fail when used."))
            }
        }
    }

    private mutating func planRename(from target: SchemaObject, to source: SchemaObject) {
        actions.append(DeploymentAction(kind: .rename, key: source.key,
                                        detail: "\(target.qualifiedName) → \(source.qualifiedName)"))
        var batches: [String] = []
        if target.schema.lowercased() != source.schema.lowercased(), target.type.isSchemaScoped {
            batches.append("ALTER SCHEMA \(SQLIdentifier.quote(source.schema)) TRANSFER "
                           + "\(target.type == .userDefinedType || target.type == .tableType ? "TYPE::" : "")"
                           + target.quotedName)
        }
        if target.name != source.name {
            let current = SQLIdentifier.quote(schema: source.schema, name: target.name)
            batches.append("EXEC sp_rename \(SQLIdentifier.literal(current)), \(SQLIdentifier.literal(source.name)), N'OBJECT'")
        }
        addStep(.rename, key: source.key, title: "Renaming \(label(target))", batches: batches)
    }

    private mutating func planAlter(_ source: SchemaObject, _ target: SchemaObject, originalTarget: SchemaObject,
                                    difference: SchemaDifference, isDependency: Bool) {
        let name = label(source)
        switch source.type {
        case .table:
            let map = SchemaComparer(options: options, filter: comparison.filter, mappings: comparison.mappings)
                .columnMap(for: difference.sourceKey ?? source.key, target: originalTarget.key)
            let change = tablePlanner.plan(desired: source, actual: target, columnMap: map)
            tableChanges[source.key.matchKey] = change
            warnings.append(contentsOf: change.warnings)
            actions.append(DeploymentAction(kind: change.rebuild ? .rebuild : .alter, key: source.key,
                                            detail: change.rebuildReasons.joined(separator: "; "),
                                            isDependency: isDependency))
            addStep(.preTransaction, key: source.key, title: "Dropping full-text index from \(name)",
                    batches: change.preTransactionBatches)
            addStep(.main, key: source.key, title: change.rebuild ? "Rebuilding \(name)" : "Altering \(name)",
                    batches: change.mainBatches)
            addStep(.post, key: source.key, title: "Enabling system versioning on \(name)", batches: change.postBatches)
            addStep(.postTransaction, key: source.key, title: "Creating full-text index on \(name)",
                    batches: change.postTransactionBatches)
            if change.touchesExistingColumns || change.rebuild {
                for dependent in dependents[originalTarget.key.matchKey] ?? [] {
                    guard let other = actual[dependent.matchKey] else { continue }
                    if other.isSchemaBound || other.type == .securityPolicy { cascade(other, because: originalTarget) }
                }
            }

        case .view, .function, .storedProcedure, .rule, .defaultObject, .ddlTrigger:
            if source.isEncrypted {
                warnings.append(DeploymentWarning(severity: .high, object: source.qualifiedName,
                                                  message: "The object is encrypted in the source, so it cannot be altered."))
                return
            }
            let familyChanges = source.type == .function && source.functionFamily != target.functionFamily
            let clrChanges = source.isCLR != target.isCLR
            let mustRecreate = options.dropAndCreateInsteadOfAlter || familyChanges || clrChanges
                || source.type == .rule || source.type == .defaultObject || target.isEncrypted
            if mustRecreate {
                planDropAndCreate(source, target, isDependency: isDependency, reason: familyChanges
                                  ? "the function kind changes" : nil)
                if source.isSchemaBound || source.type == .function {
                    for dependent in dependents[originalTarget.key.matchKey] ?? [] {
                        guard let other = actual[dependent.matchKey] else { continue }
                        if other.isSchemaBound || other.type == .securityPolicy { cascade(other, because: originalTarget) }
                    }
                }
                return
            }
            actions.append(DeploymentAction(kind: .alter, key: source.key, isDependency: isDependency))
            var batches = alterModuleBatches(source, target)
            batches.append(contentsOf: tablePlanner.securityBatches(source, previous: target))
            addStep(.main, key: source.key, title: "Altering \(name)", batches: batches)
            // ALTER on a schema-bound view or function fails while schema-bound objects use it.
            if source.type == .view || source.type == .function {
                for dependent in dependents[originalTarget.key.matchKey] ?? [] {
                    guard let other = actual[dependent.matchKey] else { continue }
                    if other.isSchemaBound { cascade(other, because: originalTarget) }
                }
            }

        case .schema, .role:
            actions.append(DeploymentAction(kind: .alter, key: source.key, isDependency: isDependency))
            var batches: [String] = []
            if (source.owner ?? "dbo").lowercased() != (target.owner ?? "dbo").lowercased() {
                let securable = source.type == .schema ? "SCHEMA" : "ROLE"
                batches.append("ALTER AUTHORIZATION ON \(securable)::\(SQLIdentifier.quote(source.name)) TO "
                               + SQLIdentifier.quote(source.owner ?? "dbo"))
            }
            var withoutOwner = source
            withoutOwner.owner = target.owner
            batches.append(contentsOf: membershipBatches(source, target))
            batches.append(contentsOf: tablePlanner.securityBatches(withoutOwner, previous: target))
            addStep(.main, key: source.key, title: "Altering \(name)", batches: batches)

        case .user, .applicationRole:
            actions.append(DeploymentAction(kind: .alter, key: source.key, isDependency: isDependency))
            var batches: [String] = []
            if let statements = alterPrincipalStatements(source, target) {
                batches.append(contentsOf: statements)
                batches.append(contentsOf: membershipBatches(source, target))
                batches.append(contentsOf: tablePlanner.securityBatches(source, previous: target))
            } else {
                warnings.append(DeploymentWarning(severity: .medium, object: source.qualifiedName,
                                                  message: "The user cannot be altered in place and is dropped and "
                                                  + "re-created; its permissions and memberships are re-applied."))
                batches.append(writer.dropStatement(for: target))
                batches.append(contentsOf: createBatches(source))
            }
            addStep(.main, key: source.key, title: "Altering \(name)", batches: batches)

        case .sequence:
            if let statements = alterSequenceStatements(source, target) {
                actions.append(DeploymentAction(kind: .alter, key: source.key, isDependency: isDependency))
                var batches = statements
                batches.append(contentsOf: tablePlanner.securityBatches(source, previous: target))
                addStep(.main, key: source.key, title: "Altering \(name)", batches: batches)
            } else {
                planDropAndCreate(source, target, isDependency: isDependency, reason: "its data type changes")
                warnings.append(DeploymentWarning(severity: .medium, object: source.qualifiedName,
                                                  message: "The sequence is dropped and re-created because its type "
                                                  + "changes; defaults that use it must be re-created too."))
            }

        case .userDefinedType, .tableType, .xmlSchemaCollection:
            planDropAndCreate(source, target, isDependency: isDependency, reason: nil)
            convertDependents(of: originalTarget, desired: source)

        case .queue:
            actions.append(DeploymentAction(kind: .alter, key: source.key, isDependency: isDependency))
            var batches = [alterQueueStatement(source, target)]
            batches.append(contentsOf: tablePlanner.securityBatches(source, previous: target))
            addStep(.main, key: source.key, title: "Altering \(name)", batches: batches)

        case .assembly:
            actions.append(DeploymentAction(kind: .alter, key: source.key, isDependency: isDependency))
            var batches = alterAssemblyStatements(source, target)
            batches.append(contentsOf: tablePlanner.securityBatches(source, previous: target))
            addStep(.main, key: source.key, title: "Altering \(name)", batches: batches)

        case .partitionFunction:
            if let statements = alterPartitionFunctionStatements(source, target) {
                actions.append(DeploymentAction(kind: .alter, key: source.key, isDependency: isDependency))
                addStep(.main, key: source.key, title: "Altering \(name)", batches: statements)
            } else {
                warnings.append(DeploymentWarning(severity: .high, object: source.qualifiedName,
                                                  message: "The partition function's type or range changes. That needs "
                                                  + "every partitioned table rebuilt, which is not scripted."))
            }

        case .partitionScheme:
            if (dependents[originalTarget.key.matchKey] ?? []).isEmpty {
                planDropAndCreate(source, target, isDependency: isDependency, reason: nil)
            } else {
                warnings.append(DeploymentWarning(severity: .high, object: source.qualifiedName,
                                                  message: "The partition scheme is in use, and changing its filegroups "
                                                  + "needs the tables on it rebuilt, which is not scripted."))
            }

        case .fullTextCatalog:
            actions.append(DeploymentAction(kind: .alter, key: source.key, isDependency: isDependency))
            addStep(.postTransaction, key: source.key, title: "Altering \(name)",
                    batches: alterFullTextCatalogStatements(source, target))

        default:
            // Synonyms, stoplists, security policies, Service Broker objects.
            planDropAndCreate(source, target, isDependency: isDependency, reason: nil)
            for dependent in dependents[originalTarget.key.matchKey] ?? [] {
                guard let other = actual[dependent.matchKey] else { continue }
                if [.contract, .service, .securityPolicy].contains(other.type) { cascade(other, because: originalTarget) }
            }
        }
    }

    private mutating func planDropAndCreate(_ source: SchemaObject, _ target: SchemaObject, isDependency: Bool,
                                            reason: String?) {
        actions.append(DeploymentAction(kind: .dropAndCreate, key: source.key, detail: reason ?? "",
                                        isDependency: isDependency))
        recreated.insert(target.key.matchKey)
        let fullText = isFullText(source.type)
        addStep(fullText ? .postTransaction : .drop, key: target.key, title: "Dropping \(label(target))",
                batches: dropBatches(target), actualSide: true)
        addStep(fullText ? .postTransaction : .main, key: source.key, title: "Creating \(label(source))",
                batches: createBatches(source))
    }

    /// Drop and re-create an object that is in the way of another change. The source's
    /// version is used when the object is part of the deployment, otherwise the target's own
    /// definition is put back.
    private mutating func cascade(_ object: SchemaObject, because blocker: SchemaObject) {
        let key = object.key.matchKey
        guard !dropped.contains(key), !recreated.contains(key) else { return }
        recreated.insert(key)
        let replacement: SchemaObject
        if let difference = deploying[key], let source = difference.source {
            replacement = source
            // Its own alter step is superseded by the re-create.
            steps.removeAll { $0.key?.matchKey == key && $0.phase == .main }
            actions.removeAll { $0.key.matchKey == key && $0.kind == .alter }
        } else {
            replacement = object
        }
        actions.append(DeploymentAction(kind: .recreateDependent, key: object.key,
                                        detail: "needed by the change to \(blocker.qualifiedName)", isDependency: true))
        addStep(.drop, key: object.key, title: "Dropping \(label(object))", batches: dropBatches(object), actualSide: true)
        addStep(.main, key: replacement.key, title: "Creating \(label(replacement))", batches: createBatches(replacement))
        for dependent in dependents[key] ?? [] {
            guard let other = actual[dependent.matchKey] else { continue }
            if other.isSchemaBound || other.type == .securityPolicy { cascade(other, because: object) }
        }
    }

    /// A user-defined type, table type or XML schema collection is being dropped and created
    /// again: modules using it are re-created, and table columns of that type are converted to
    /// the underlying type for the duration.
    private mutating func convertDependents(of type: SchemaObject, desired: SchemaObject) {
        for dependent in dependents[type.key.matchKey] ?? [] {
            guard let other = actual[dependent.matchKey], !dropped.contains(other.key.matchKey) else { continue }
            switch other.type {
            case .table:
                convertColumns(of: other, from: type, to: desired)
            case .view, .function, .storedProcedure, .tableType, .securityPolicy:
                cascade(other, because: type)
            default:
                break
            }
        }
    }

    private mutating func convertColumns(of table: SchemaObject, from type: SchemaObject, to desired: SchemaObject) {
        guard let definition = table.table else { return }
        let columns = definition.columns.filter { column in
            if type.type == .xmlSchemaCollection {
                return column.dataType.lowercased().contains(type.quotedName.lowercased())
            }
            return column.isUserDefinedType
                && SchemaTypes.baseName(of: column.dataType) == "\(type.schema).\(type.name)".lowercased()
        }
        guard !columns.isEmpty else { return }
        let names = Set(columns.map { $0.name.lowercased() })
        let target = table.quotedName
        let baseType: String
        if type.type == .xmlSchemaCollection {
            baseType = "xml"
        } else {
            baseType = PlanBuilder.aliasBaseType(type.body) ?? "sql_variant"
        }

        var off: [String] = []
        var on: [String] = []
        // Anything built on the columns has to let go of them while they change type.
        for column in definition.columns where names.contains(column.name.lowercased()) {
            if let constraint = column.defaultConstraint {
                off.append(writer.dropConstraintStatement(name: constraint.name, table: target))
            }
        }
        for check in definition.checkConstraints where tablePlanner.references(check.definition, names) {
            off.append(writer.dropConstraintStatement(name: check.name, table: target))
            on.append(contentsOf: writer.checkConstraintBatches(check, table: target))
        }
        var keySets: [Set<String>] = []
        for index in table.indexes {
            let used = Set((index.columns.map(\.name) + index.includedColumns).map { $0.lowercased() })
            guard !used.isDisjoint(with: names) else { continue }
            off.insert(writer.dropIndexStatement(name: index.name, on: target), at: 0)
            on.append(contentsOf: writer.createIndexBatches(index, on: target))
            if index.isUnique { keySets.append(Set(index.columns.map { $0.name.lowercased() })) }
        }
        for key in definition.uniqueConstraints + [definition.primaryKey].compactMap({ $0 }) {
            let used = Set(key.columns.map { $0.name.lowercased() })
            guard !used.isDisjoint(with: names) else { continue }
            off.append(writer.dropConstraintStatement(name: key.name, table: target))
            on.insert(writer.addKeyConstraintStatement(key, table: target), at: 0)
            keySets.append(used)
        }
        for column in columns {
            let nullability = column.isNullable ? "NULL" : "NOT NULL"
            off.append("ALTER TABLE \(target) ALTER COLUMN \(SQLIdentifier.quote(column.name)) \(baseType) \(nullability)")
            var restored = column
            if type.type == .xmlSchemaCollection {
                restored.dataType = column.dataType.replacingOccurrences(of: type.quotedName, with: desired.quotedName)
            } else {
                restored.dataType = desired.quotedName
            }
            on.insert("ALTER TABLE \(target) ALTER COLUMN \(SQLIdentifier.quote(column.name)) \(restored.dataType) "
                      + nullability, at: 0)
            if let constraint = column.defaultConstraint {
                on.append(writer.addDefaultStatement(constraint, column: column.name, table: target))
            }
        }
        convertedColumns[table.key.matchKey, default: []].formUnion(names)
        convertedKeys[table.key.matchKey, default: []].append(contentsOf: keySets)
        addStep(.drop, key: table.key, title: "Converting columns of \(label(table)) away from \(type.qualifiedName)",
                batches: off, actualSide: true)
        addStep(.main, key: table.key, title: "Converting columns of \(label(table)) back to \(desired.qualifiedName)",
                batches: on)
        warnings.append(DeploymentWarning(severity: .medium, object: table.qualifiedName,
                                          message: "Columns of type \(type.qualifiedName) are converted to \(baseType) "
                                          + "while the type is re-created, then converted back."))
    }

    // MARK: - Foreign keys

    private mutating func planForeignKeys() {
        let rebuilt: Set<String> = Set(tableChanges.filter { $0.value.rebuild }.map(\.key))
        func affected(_ table: String) -> Set<String> {
            (tableChanges[table]?.affectedColumns ?? []).union(convertedColumns[table] ?? [])
        }
        func recreatedKeySets(_ table: String) -> [Set<String>] {
            (tableChanges[table]?.recreatedKeys ?? []) + (convertedKeys[table] ?? [])
        }

        // The final shape of every table: deployed ones as desired, the rest as they are.
        var finalTables: [String: SchemaObject] = [:]
        for object in actual.values where object.type == .table && !dropped.contains(object.key.matchKey) {
            finalTables[object.key.matchKey] = object
        }
        for difference in deploying.values where difference.type == .table {
            if let target = difference.target { finalTables.removeValue(forKey: target.key.matchKey) }
            if let source = difference.source, difference.status != .onlyInTarget {
                finalTables[source.key.matchKey] = source
            }
        }

        // Map old table keys to new ones for renamed tables.
        var renamedTo: [String: String] = [:]
        for difference in deploying.values where difference.type == .table && difference.status == .different {
            if let source = difference.source, let target = difference.target, source.key != target.key {
                renamedTo[target.key.matchKey] = source.key.matchKey
            }
        }

        var kept: Set<String> = []
        for object in actual.values where object.type == .table {
            let tableKey = renamedTo[object.key.matchKey] ?? object.key.matchKey
            for key in object.table?.foreignKeys ?? [] {
                let referenced = renamedTo[key.referencedKey.matchKey] ?? key.referencedKey.matchKey
                var keep = !dropped.contains(object.key.matchKey) && !rebuilt.contains(tableKey)
                    && !dropped.contains(key.referencedKey.matchKey) && !rebuilt.contains(referenced)
                    && affected(tableKey).isDisjoint(with: key.columns.map { $0.lowercased() })
                let referencedColumns = Set(key.referencedColumns.map { $0.lowercased() })
                if recreatedKeySets(referenced).contains(referencedColumns) { keep = false }
                if keep, let final = finalTables[tableKey]?.table {
                    keep = final.foreignKeys.contains { candidate in
                        sameForeignKey(candidate, key, referencedRename: renamedTo)
                    }
                } else {
                    keep = false
                }
                let identity = tableKey + "|" + key.name.lowercased()
                if keep {
                    kept.insert(identity)
                } else {
                    addStep(.dropForeignKeys, key: nil,
                            title: "Dropping foreign key \(SQLIdentifier.quote(key.name)) from \(object.quotedName)",
                            batches: [writer.dropConstraintStatement(name: key.name, table: object.quotedName)])
                }
            }
        }
        for (tableKey, object) in finalTables.sorted(by: { $0.key < $1.key }) {
            for key in object.table?.foreignKeys ?? [] {
                let existing = actual.values.first { candidate in
                    (renamedTo[candidate.key.matchKey] ?? candidate.key.matchKey) == tableKey
                }
                let match = existing?.table?.foreignKeys.first { sameForeignKey(key, $0, referencedRename: renamedTo) }
                if let match, kept.contains(tableKey + "|" + match.name.lowercased()) { continue }
                addStep(.addForeignKeys, key: object.key,
                        title: "Adding foreign key \(SQLIdentifier.quote(key.name)) to \(object.quotedName)",
                        batches: writer.foreignKeyBatches(key, table: object.quotedName))
            }
        }
    }

    private func sameForeignKey(_ a: ForeignKeyDefinition, _ b: ForeignKeyDefinition,
                                referencedRename: [String: String]) -> Bool {
        let namesMatch: Bool
        if options.ignoreConstraintAndIndexNames {
            namesMatch = true
        } else if options.ignoreSystemNamedConstraintNames && a.isSystemNamed && b.isSystemNamed {
            namesMatch = true
        } else {
            namesMatch = a.name.lowercased() == b.name.lowercased()
        }
        guard namesMatch else { return false }
        let aRef = referencedRename[a.referencedKey.matchKey] ?? a.referencedKey.matchKey
        let bRef = referencedRename[b.referencedKey.matchKey] ?? b.referencedKey.matchKey
        guard aRef == bRef,
              a.columns.map({ $0.lowercased() }) == b.columns.map({ $0.lowercased() }),
              a.referencedColumns.map({ $0.lowercased() }) == b.referencedColumns.map({ $0.lowercased() }),
              a.deleteAction.uppercased() == b.deleteAction.uppercased(),
              a.updateAction.uppercased() == b.updateAction.uppercased() else { return false }
        if !options.ignoreWithNoCheck, a.isNotTrusted != b.isNotTrusted || a.isDisabled != b.isDisabled {
            return false
        }
        if !options.ignoreNotForReplication, a.isNotForReplication != b.isNotForReplication { return false }
        return true
    }

    private mutating func planViewRefreshes() {
        guard options.refreshDependentViews else { return }
        var refreshed: Set<String> = []
        for (tableKey, change) in tableChanges where !createdTables.contains(tableKey) {
            guard change.touchesExistingColumns || change.rebuild || !change.mainBatches.isEmpty else { continue }
            let originalKey = deploying[tableKey]?.target?.key.matchKey ?? tableKey
            for dependent in dependents[originalKey] ?? [] {
                let key = dependent.matchKey
                guard let view = actual[key], view.type == .view, !view.isSchemaBound,
                      !dropped.contains(key), !recreated.contains(key), deploying[key] == nil,
                      refreshed.insert(key).inserted else { continue }
                addStep(.post, key: view.key, title: "Refreshing \(label(view))",
                        batches: ["EXEC sp_refreshview \(SQLIdentifier.literal(view.quotedName))"])
            }
        }
    }

    // MARK: - Statement builders

    private func createBatches(_ object: SchemaObject) -> [String] {
        var batches = writer.batches(for: object)
        if object.type == .user || object.type == .applicationRole {
            batches = batches.map { $0.replacingOccurrences(of: "N'<password>'", with: SQLIdentifier.literal(randomPassword())) }
        }
        guard options.addObjectExistenceChecks else { return batches }
        return batches.map { guardCreate($0, object: object) }
    }

    private func guardCreate(_ batch: String, object: SchemaObject) -> String {
        let trimmed = batch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("CREATE") else { return batch }
        let condition: String
        switch object.type {
        case .schema: condition = "SCHEMA_ID(\(SQLIdentifier.literal(object.name))) IS NULL"
        case .user, .role, .applicationRole:
            condition = "DATABASE_PRINCIPAL_ID(\(SQLIdentifier.literal(object.name))) IS NULL"
        case .userDefinedType, .tableType: condition = "TYPE_ID(\(SQLIdentifier.literal(object.quotedName))) IS NULL"
        case .ddlTrigger:
            condition = "NOT EXISTS (SELECT 1 FROM sys.triggers WHERE parent_class = 0 AND name = "
                + "\(SQLIdentifier.literal(object.name)))"
        default:
            guard object.type.isSchemaScoped else { return batch }
            // Only the object's own CREATE is guarded, not its indexes or triggers.
            guard let header = ModuleText.header(of: trimmed), header.kind != "TRIGGER" || object.type == .ddlTrigger
            else {
                if trimmed.uppercased().hasPrefix("CREATE SEQUENCE") || trimmed.uppercased().hasPrefix("CREATE SYNONYM") {
                    return "IF OBJECT_ID(\(SQLIdentifier.literal(object.quotedName))) IS NULL\n"
                        + "EXEC sp_executesql \(SQLIdentifier.literal(trimmed))"
                }
                return batch
            }
            condition = "OBJECT_ID(\(SQLIdentifier.literal(object.quotedName))) IS NULL"
        }
        return "IF \(condition)\nEXEC sp_executesql \(SQLIdentifier.literal(trimmed))"
    }

    private func dropBatches(_ object: SchemaObject) -> [String] {
        var statement = writer.dropStatement(for: object)
        if object.type == .function, object.subtype.uppercased() == "AF" {
            statement = "DROP AGGREGATE \(object.quotedName)"
        }
        if object.type == .rule || object.type == .defaultObject {
            // Legacy rules and defaults must be unbound from every column first.
            var batches: [String] = []
            for table in actual.values where table.type == .table {
                for column in table.table?.columns ?? [] {
                    let path = table.quotedName + "." + SQLIdentifier.quote(column.name)
                    if object.type == .rule, column.boundRule?.lowercased() == object.quotedName.lowercased() {
                        batches.append("EXEC sp_unbindrule \(SQLIdentifier.literal(path))")
                    }
                    if object.type == .defaultObject, column.boundDefault?.lowercased() == object.quotedName.lowercased() {
                        batches.append("EXEC sp_unbindefault \(SQLIdentifier.literal(path))")
                    }
                }
            }
            return batches + [statement]
        }
        if options.addObjectExistenceChecks {
            let supportsIfExists: Set<SchemaObjectType> = [.table, .view, .storedProcedure, .function, .synonym,
                                                           .sequence, .userDefinedType, .tableType, .schema, .user,
                                                           .role, .assembly, .securityPolicy]
            if supportsIfExists.contains(object.type), object.subtype.uppercased() != "AF" {
                let keyword = object.type.dropKeyword
                statement = statement.replacingOccurrences(of: "DROP \(keyword) ", with: "DROP \(keyword) IF EXISTS ")
            }
        }
        return [statement]
    }

    private func alterModuleBatches(_ source: SchemaObject, _ target: SchemaObject) -> [String] {
        var batches = writer.moduleBatches(source, verb: "ALTER")
        if source.type == .ddlTrigger {
            batches.append("\(source.subtype == "disabled" ? "DISABLE" : "ENABLE") TRIGGER "
                           + "\(SQLIdentifier.quote(source.name)) ON DATABASE")
            if source.triggerOrder != target.triggerOrder {
                batches.append(contentsOf: writer.ddlTriggerStateBatches(source).filter { $0.hasPrefix("EXEC") })
            }
        }
        if source.type == .view {
            // ALTER VIEW drops every index on the view; put them back.
            batches.append(contentsOf: source.indexes.sorted { a, b in
                (a.kind == .clustered ? 0 : 1, a.name.lowercased()) < (b.kind == .clustered ? 0 : 1, b.name.lowercased())
            }.flatMap { writer.createIndexBatches($0, on: source.quotedName) })
            let triggers = source.triggers.filter { wanted in
                !target.triggers.contains { $0 == wanted }
            }
            for trigger in target.triggers where !source.triggers.contains(where: { $0.name.lowercased() == trigger.name.lowercased() }) {
                batches.append("DROP TRIGGER \(SQLIdentifier.quote(schema: target.schema, name: trigger.name))")
            }
            for trigger in triggers {
                if target.triggers.contains(where: { $0.name.lowercased() == trigger.name.lowercased() }) {
                    batches.append("DROP TRIGGER \(SQLIdentifier.quote(schema: source.schema, name: trigger.name))")
                }
                batches.append(contentsOf: writer.triggerBatches(trigger, schema: source.schema, target: source.quotedName))
            }
        }
        return batches
    }

    private func membershipBatches(_ source: SchemaObject, _ target: SchemaObject) -> [String] {
        let wanted = Set(source.roleMemberships.map { $0.lowercased() })
        let have = Set(target.roleMemberships.map { $0.lowercased() })
        var batches: [String] = []
        for role in source.roleMemberships where !have.contains(role.lowercased()) {
            batches.append(writer.addRoleMemberStatement(role: role, member: source.name))
        }
        for role in target.roleMemberships where !wanted.contains(role.lowercased()) {
            batches.append(writer.dropRoleMemberStatement(role: role, member: source.name))
        }
        return batches
    }

    /// ALTER USER / ALTER APPLICATION ROLE statements, or nil when the principal has to be
    /// re-created.
    private func alterPrincipalStatements(_ source: SchemaObject, _ target: SchemaObject) -> [String]? {
        let a = PrincipalInfo(body: source.body)
        let b = PrincipalInfo(body: target.body)
        var clauses: [String] = []
        if source.type == .applicationRole {
            if a.defaultSchema?.lowercased() != b.defaultSchema?.lowercased() {
                clauses.append("DEFAULT_SCHEMA = \(SQLIdentifier.quote(a.defaultSchema ?? "dbo"))")
            }
            return clauses.isEmpty ? [] : ["ALTER APPLICATION ROLE \(SQLIdentifier.quote(source.name)) WITH "
                                           + clauses.joined(separator: ", ")]
        }
        guard a.kind == b.kind else { return nil }
        if a.login?.lowercased() != b.login?.lowercased() {
            guard a.kind == "LOGIN", let login = a.login else { return nil }
            clauses.append("LOGIN = \(SQLIdentifier.quote(login))")
        }
        if a.defaultSchema?.lowercased() != b.defaultSchema?.lowercased() {
            clauses.append("DEFAULT_SCHEMA = \(SQLIdentifier.quote(a.defaultSchema ?? "dbo"))")
        }
        return clauses.isEmpty ? [] : ["ALTER USER \(SQLIdentifier.quote(source.name)) WITH "
                                       + clauses.joined(separator: ", ")]
    }

    private mutating func alterSequenceStatements(_ source: SchemaObject, _ target: SchemaObject) -> [String]? {
        let a = SequenceInfo(body: source.body)
        let b = SequenceInfo(body: target.body)
        guard a.type.lowercased() == b.type.lowercased() else { return nil }
        if a.start != b.start, !options.ignoreSequenceStartValue {
            warnings.append(DeploymentWarning(severity: .low, object: source.qualifiedName,
                                              message: "START WITH differs (\(b.start) → \(a.start)). The sequence's "
                                              + "current value is left alone; use ALTER SEQUENCE … RESTART to reset it."))
        }
        var clauses: [String] = []
        if a.increment != b.increment { clauses.append("INCREMENT BY \(a.increment)") }
        if a.minimum != b.minimum { clauses.append("MINVALUE \(a.minimum)") }
        if a.maximum != b.maximum { clauses.append("MAXVALUE \(a.maximum)") }
        if a.cycle != b.cycle { clauses.append(a.cycle ? "CYCLE" : "NO CYCLE") }
        if a.cache != b.cache { clauses.append(a.cache) }
        guard !clauses.isEmpty else { return [] }
        return ["ALTER SEQUENCE \(source.quotedName)\n    " + clauses.joined(separator: "\n    ")]
    }

    private func alterQueueStatement(_ source: SchemaObject, _ target: SchemaObject) -> String {
        var text = source.body.replacingOccurrences(of: "CREATE QUEUE", with: "ALTER QUEUE")
        if target.body.contains("ACTIVATION ("), !source.body.contains("ACTIVATION (") {
            text = text.replacingOccurrences(of: ", POISON_MESSAGE_HANDLING", with: ", ACTIVATION (DROP), POISON_MESSAGE_HANDLING")
        }
        return text
    }

    private func alterAssemblyStatements(_ source: SchemaObject, _ target: SchemaObject) -> [String] {
        func part(_ body: String, after marker: String) -> String {
            guard let range = body.range(of: marker) else { return "" }
            let rest = body[range.upperBound...]
            return String(rest.prefix { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        }
        var batches: [String] = []
        let bytes = part(source.body, after: "FROM ")
        if bytes != part(target.body, after: "FROM ") {
            batches.append("ALTER ASSEMBLY \(SQLIdentifier.quote(source.name)) FROM \(bytes) WITH UNCHECKED DATA")
        }
        let permission = part(source.body, after: "PERMISSION_SET = ")
        if permission != part(target.body, after: "PERMISSION_SET = ") {
            batches.append("ALTER ASSEMBLY \(SQLIdentifier.quote(source.name)) WITH PERMISSION_SET = \(permission)")
        }
        return batches
    }

    private func alterFullTextCatalogStatements(_ source: SchemaObject, _ target: SchemaObject) -> [String] {
        var batches: [String] = []
        let name = SQLIdentifier.quote(source.name)
        let accent = source.body.contains("ACCENT_SENSITIVITY = ON")
        if accent != target.body.contains("ACCENT_SENSITIVITY = ON") {
            batches.append("ALTER FULLTEXT CATALOG \(name) REBUILD WITH ACCENT_SENSITIVITY = \(accent ? "ON" : "OFF")")
        }
        if source.body.contains("AS DEFAULT"), !target.body.contains("AS DEFAULT") {
            batches.append("ALTER FULLTEXT CATALOG \(name) AS DEFAULT")
        }
        return batches
    }

    private func alterPartitionFunctionStatements(_ source: SchemaObject, _ target: SchemaObject) -> [String]? {
        let a = PartitionFunctionInfo(body: source.body)
        let b = PartitionFunctionInfo(body: target.body)
        guard a.type.lowercased() == b.type.lowercased(), a.isRight == b.isRight else { return nil }
        var batches: [String] = []
        let name = SQLIdentifier.quote(source.name)
        let schemes: [SchemaObject] = (dependents[target.key.matchKey] ?? []).compactMap { actual[$0.matchKey] }
            .filter { $0.type == .partitionScheme }
        for value in b.values where !a.values.contains(value) {
            batches.append("ALTER PARTITION FUNCTION \(name)() MERGE RANGE (\(value))")
        }
        for value in a.values where !b.values.contains(value) {
            for scheme in schemes {
                let filegroup = PartitionFunctionInfo.lastFilegroup(desired[scheme.key.matchKey]?.body ?? scheme.body)
                batches.append("ALTER PARTITION SCHEME \(SQLIdentifier.quote(scheme.name)) NEXT USED \(filegroup)")
            }
            batches.append("ALTER PARTITION FUNCTION \(name)() SPLIT RANGE (\(value))")
        }
        return batches
    }

    // MARK: - Steps

    private mutating func addStep(_ phase: DeploymentPhase, key: SchemaObjectKey?, title: String, batches: [String],
                                  actualSide: Bool = false) {
        let nonEmpty = batches.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        var step = DeploymentStep(phase: phase, key: key, title: title, batches: nonEmpty)
        step.sequence = sequence
        sequence += 1
        steps.append(step)
    }

    private func label(_ object: SchemaObject) -> String {
        "\(object.type.title.lowercased()) \(object.type == .ddlTrigger ? SQLIdentifier.quote(object.name) : object.quotedName)"
    }

    private func isFullText(_ type: SchemaObjectType) -> Bool {
        type == .fullTextCatalog || type == .fullTextStoplist
    }

    private func randomPassword() -> String {
        "Aa1!" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static func aliasBaseType(_ body: String) -> String? {
        // "CREATE TYPE [dbo].[Phone] FROM nvarchar(20) NOT NULL"
        guard let range = body.range(of: " FROM ", options: .caseInsensitive) else { return nil }
        var rest = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" NOT NULL", " NULL"] where rest.uppercased().hasSuffix(suffix) {
            rest = String(rest.dropLast(suffix.count))
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Ordering and assembly

    func finish() -> DeploymentPlan {
        let ordered = orderedSteps()
        let script = assemble(ordered)
        let sortedWarnings = warnings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
            return lhs.object.lowercased() < rhs.object.lowercased()
        }
        return DeploymentPlan(actions: actions, warnings: sortedWarnings, dependencies: dependencyKeys,
                              steps: ordered, script: script)
    }

    private func orderedSteps() -> [DeploymentStep] {
        var result: [DeploymentStep] = []
        for phase in DeploymentPhase.allCases.sorted() {
            let inPhase = steps.filter { $0.phase == phase }.sorted { $0.sequence < $1.sequence }
            guard !inPhase.isEmpty else { continue }
            let reverse = phase == .drop || phase == .lateDrop || phase == .dropForeignKeys || phase == .preTransaction
            let graph = reverse ? actualGraph : desiredGraph
            result.append(contentsOf: topologicalOrder(inPhase, graph: graph, reverse: reverse))
        }
        return result
    }

    /// Kahn's algorithm over the steps of one phase. Ties go to the object type order
    /// (reversed for drops), then name, then the order the steps were planned in.
    private func topologicalOrder(_ items: [DeploymentStep], graph: [String: Set<String>], reverse: Bool) -> [DeploymentStep] {
        let count = items.count
        var successors: [[Int]] = Array(repeating: [], count: count)
        var indegree: [Int] = Array(repeating: 0, count: count)
        var byKey: [String: [Int]] = [:]
        for (index, step) in items.enumerated() {
            if let key = step.key { byKey[key.matchKey, default: []].append(index) }
        }
        func edge(_ from: Int, _ to: Int) {
            guard from != to, !successors[from].contains(to) else { return }
            successors[from].append(to)
            indegree[to] += 1
        }
        for (_, indices) in byKey {
            for pair in zip(indices, indices.dropFirst()) { edge(pair.0, pair.1) }
        }
        for (index, step) in items.enumerated() {
            guard let key = step.key else { continue }
            for referenced in graph[key.matchKey] ?? [] {
                guard let others = byKey[referenced] else { continue }
                for other in others {
                    // reverse: the referencing object goes first (drops).
                    if reverse { edge(index, other) } else { edge(other, index) }
                }
            }
        }

        func priority(_ index: Int) -> (Int, String, Int) {
            let step = items[index]
            let typeOrder = step.key.map { $0.type.creationOrder } ?? -1
            let rank = reverse ? -typeOrder : typeOrder
            return (rank, step.key?.qualifiedName.lowercased() ?? "", step.sequence)
        }

        var ready = (0..<count).filter { indegree[$0] == 0 }
        var emitted: [Bool] = Array(repeating: false, count: count)
        var output: [DeploymentStep] = []
        while output.count < count {
            if ready.isEmpty {
                // A cycle: release the highest-priority remaining step.
                guard let next = (0..<count).filter({ !emitted[$0] }).min(by: { priority($0) < priority($1) }) else { break }
                ready.append(next)
                indegree[next] = 0
            }
            ready.sort { priority($0) < priority($1) }
            let current = ready.removeFirst()
            guard !emitted[current] else { continue }
            emitted[current] = true
            output.append(items[current])
            for next in successors[current] where !emitted[next] {
                indegree[next] -= 1
                if indegree[next] == 0 { ready.append(next) }
            }
        }
        return output
    }

    private func assemble(_ ordered: [DeploymentStep]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var out = """
        /*
            Deployment script generated by SSMS for Mac Schema Compare

            Source: \(comparison.source.origin)
            Target: \(comparison.target.origin)
            Date:   \(formatter.string(from: Date()))

            Back up the target database before running this script.
        */

        """
        let go = "GO\n"
        let check = options.doNotAddErrorHandling ? "" : "IF @@ERROR <> 0 SET NOEXEC ON\n" + go
        func emit(_ step: DeploymentStep, errorCheck: Bool) -> String {
            var text = ""
            if options.includePrintStatements {
                text += "PRINT \(SQLIdentifier.literal(step.title))\n" + go
            }
            for batch in step.batches {
                text += batch + "\n" + go
                if errorCheck { text += check }
            }
            return text
        }

        out += "SET NUMERIC_ROUNDABORT OFF\n" + go
        out += "SET ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL, ARITHABORT, QUOTED_IDENTIFIER, "
            + "ANSI_NULLS ON\n" + go
        if options.addDatabaseUseStatement, !targetDatabaseName.isEmpty {
            out += "USE \(SQLIdentifier.quote(targetDatabaseName))\n" + go
        }
        let pre = ordered.filter { $0.phase == .preTransaction }
        let transactional = ordered.filter { $0.phase.isTransactional }
        let post = ordered.filter { $0.phase == .postTransaction }
        for step in pre { out += emit(step, errorCheck: false) }

        if transactional.isEmpty {
            // Nothing to wrap.
        } else if options.doNotUseTransactions {
            for step in transactional { out += emit(step, errorCheck: false) }
        } else {
            out += "SET XACT_ABORT ON\n" + go
            out += "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE\n" + go
            out += "BEGIN TRANSACTION\n" + go
            out += check
            for step in transactional { out += emit(step, errorCheck: true) }
            out += "COMMIT TRANSACTION\n" + go
            out += check
            if !options.doNotAddErrorHandling {
                // With NOEXEC on after a failure, the assignment never runs, so @Success stays
                // NULL and the else branch reports it.
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
        }
        for step in post { out += emit(step, errorCheck: false) }
        return out
    }
}

// MARK: - Parsed catalog bodies

/// Fields of a `CREATE USER` statement generated by the reader.
private struct PrincipalInfo {
    var kind = "LOGIN"
    var login: String?
    var defaultSchema: String?

    init(body: String) {
        let tokens = TSQLLexer().significantTokens(body)
        let words = tokens.map { $0.text.uppercased() }
        if words.contains("WITHOUT") { kind = "NONE" }
        else if words.contains("EXTERNAL") { kind = "EXTERNAL" }
        else if words.contains("CERTIFICATE") { kind = "CERTIFICATE" }
        else if words.contains("ASYMMETRIC") { kind = "ASYMMETRIC" }
        else if words.contains("PASSWORD") && !words.contains("LOGIN") { kind = "PASSWORD" }
        for (index, word) in words.enumerated() {
            if word == "LOGIN", index > 0, words[index - 1] == "FOR", index + 1 < tokens.count {
                login = ModuleText.unquote(tokens[index + 1].text)
            }
            if word == "DEFAULT_SCHEMA", index + 2 < tokens.count {
                defaultSchema = ModuleText.unquote(tokens[index + 2].text)
            }
        }
    }
}

private struct SequenceInfo {
    var type = ""
    var start = ""
    var increment = ""
    var minimum = ""
    var maximum = ""
    var cycle = false
    var cache = ""

    init(body: String) {
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("AS ") { type = String(line.dropFirst(3)) }
            else if upper.hasPrefix("START WITH ") { start = String(line.dropFirst(11)) }
            else if upper.hasPrefix("INCREMENT BY ") { increment = String(line.dropFirst(13)) }
            else if upper.hasPrefix("MINVALUE ") { minimum = String(line.dropFirst(9)) }
            else if upper.hasPrefix("MAXVALUE ") { maximum = String(line.dropFirst(9)) }
            else if upper == "CYCLE" { cycle = true }
            else if upper.hasPrefix("CACHE") || upper.hasPrefix("NO CACHE") { cache = line }
        }
    }
}

private struct PartitionFunctionInfo {
    var type = ""
    var isRight = false
    var values: [String] = []

    init(body: String) {
        if let open = body.firstIndex(of: "("), let close = body[open...].firstIndex(of: ")") {
            type = String(body[body.index(after: open)..<close])
        }
        isRight = body.uppercased().contains("RANGE RIGHT")
        if let range = body.range(of: "FOR VALUES (", options: .caseInsensitive),
           let end = body.range(of: ")", options: .backwards), range.upperBound <= end.lowerBound {
            let inner = body[range.upperBound..<end.lowerBound]
            values = PartitionFunctionInfo.splitValues(String(inner))
        }
    }

    /// Splits on commas outside string literals.
    static func splitValues(_ text: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inString = false
        for character in text {
            if character == "'" { inString.toggle() }
            if character == ",", !inString {
                values.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { values.append(last) }
        return values
    }

    static func lastFilegroup(_ schemeBody: String) -> String {
        guard let range = schemeBody.range(of: "TO (", options: .caseInsensitive),
              let end = schemeBody.range(of: ")", options: .backwards) else { return "[PRIMARY]" }
        let list = splitValues(String(schemeBody[range.upperBound..<end.lowerBound]))
        return list.last ?? "[PRIMARY]"
    }
}
