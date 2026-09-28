import Foundation

/// What a schema comparison ignores and how a deployment script is written.
///
/// Every option is a plain Bool so projects, the command line and the options panel can all
/// address it by name through `descriptors`.
public struct SchemaCompareOptions: Codable, Hashable, Sendable {

    // MARK: Ignore

    public var ignoreWhitespace: Bool = true
    public var ignoreComments: Bool = false
    public var caseSensitiveDefinitions: Bool = false
    public var ignoreSquareBrackets: Bool = true
    public var ignoreCollations: Bool = false
    public var ignoreFillFactorAndIndexPadding: Bool = true
    public var ignoreFileGroups: Bool = true
    public var ignoreDataCompression: Bool = false
    public var ignoreIdentitySeedAndIncrement: Bool = true
    public var ignoreNotForReplication: Bool = false
    public var ignoreWithNoCheck: Bool = true
    public var ignoreSystemNamedConstraintNames: Bool = true
    public var ignoreConstraintAndIndexNames: Bool = false
    public var ignorePermissions: Bool = false
    public var ignoreUsersPermissionsAndRoleMemberships: Bool = false
    public var ignoreExtendedProperties: Bool = false
    public var ignoreAuthorization: Bool = false
    public var ignoreBindings: Bool = false
    public var ignoreIndexes: Bool = false
    public var ignorePerformanceIndexes: Bool = false
    public var ignoreStatistics: Bool = true
    public var ignoreDMLTriggers: Bool = false
    public var ignoreTriggerOrder: Bool = false
    public var ignoreCheckConstraints: Bool = false
    public var ignoreForeignKeys: Bool = false
    public var ignoreFullTextIndexing: Bool = false
    public var ignoreLockProperties: Bool = false
    public var ignoreTableLockEscalation: Bool = false
    public var ignoreChangeTracking: Bool = false
    public var ignoreDynamicDataMasking: Bool = false
    public var ignoreQuotedIdentifierAndAnsiNulls: Bool = false
    public var ignoreWithEncryption: Bool = false
    public var ignoreSynonymDatabaseAndServerNames: Bool = true
    public var ignoreIdentityProperty: Bool = false
    public var ignoreSparseAndColumnSets: Bool = false
    public var ignoreSequenceStartValue: Bool = true

    // MARK: Behavior

    public var forceColumnOrder: Bool = false
    public var includeDependencies: Bool = true
    public var addObjectExistenceChecks: Bool = false
    public var dropAndCreateInsteadOfAlter: Bool = false
    public var doNotUseTransactions: Bool = false
    public var doNotAddErrorHandling: Bool = false
    public var addDatabaseUseStatement: Bool = false
    public var addOnlineOption: Bool = false
    public var addSmartDefaults: Bool = true
    public var renameMappedObjects: Bool = true
    public var includePrintStatements: Bool = true
    public var refreshDependentViews: Bool = true
    public var dropDependentForeignKeys: Bool = true

    public init() {}

    public var normalization: ModuleText.Normalization {
        ModuleText.Normalization(ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments,
                                 caseSensitive: caseSensitiveDefinitions,
                                 ignoreBrackets: ignoreSquareBrackets)
    }

    // MARK: - Descriptors

    public enum Group: String, CaseIterable, Sendable {
        case ignore = "Ignore"
        case behavior = "Behavior"
    }

    public struct Descriptor: Identifiable {
        public var id: String { name }
        public let name: String
        public let title: String
        public let detail: String
        public let group: Group
        public let keyPath: WritableKeyPath<SchemaCompareOptions, Bool>
    }

    public static let descriptors: [Descriptor] = [
        Descriptor(name: "ignoreWhitespace", title: "Ignore white space",
                   detail: "Spaces, tabs and line breaks in module definitions are not compared.",
                   group: .ignore, keyPath: \.ignoreWhitespace),
        Descriptor(name: "ignoreComments", title: "Ignore comments",
                   detail: "Comments in views, procedures, functions and triggers are not compared.",
                   group: .ignore, keyPath: \.ignoreComments),
        Descriptor(name: "caseSensitiveDefinitions", title: "Case-sensitive object definitions",
                   detail: "Keyword and identifier case in definitions counts as a difference.",
                   group: .ignore, keyPath: \.caseSensitiveDefinitions),
        Descriptor(name: "ignoreSquareBrackets", title: "Ignore square brackets",
                   detail: "[Name] and Name are treated as the same identifier.",
                   group: .ignore, keyPath: \.ignoreSquareBrackets),
        Descriptor(name: "ignoreCollations", title: "Ignore collations",
                   detail: "Column collations are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreCollations),
        Descriptor(name: "ignoreFillFactorAndIndexPadding", title: "Ignore fill factor and index padding",
                   detail: "FILLFACTOR and PAD_INDEX are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreFillFactorAndIndexPadding),
        Descriptor(name: "ignoreFileGroups", title: "Ignore filegroups, partition schemes and functions",
                   detail: "Where tables and indexes are stored is not compared, and partition schemes "
                   + "and functions are left out.", group: .ignore, keyPath: \.ignoreFileGroups),
        Descriptor(name: "ignoreDataCompression", title: "Ignore data compression",
                   detail: "ROW and PAGE compression settings are not compared.",
                   group: .ignore, keyPath: \.ignoreDataCompression),
        Descriptor(name: "ignoreIdentitySeedAndIncrement", title: "Ignore identity seed and increment values",
                   detail: "IDENTITY(1,1) and IDENTITY(100,5) are treated as equal.",
                   group: .ignore, keyPath: \.ignoreIdentitySeedAndIncrement),
        Descriptor(name: "ignoreIdentityProperty", title: "Ignore identity property",
                   detail: "Whether a column is an identity column at all is not compared.",
                   group: .ignore, keyPath: \.ignoreIdentityProperty),
        Descriptor(name: "ignoreNotForReplication", title: "Ignore NOT FOR REPLICATION",
                   detail: "NOT FOR REPLICATION on identities, constraints and triggers is not compared.",
                   group: .ignore, keyPath: \.ignoreNotForReplication),
        Descriptor(name: "ignoreWithNoCheck", title: "Ignore WITH NOCHECK",
                   detail: "Whether a foreign key or check constraint is trusted or enabled is not compared.",
                   group: .ignore, keyPath: \.ignoreWithNoCheck),
        Descriptor(name: "ignoreSystemNamedConstraintNames", title: "Ignore system-named constraint names",
                   detail: "Names SQL Server generated, like DF__Orders__Statu__1A2B3C4D, are not compared.",
                   group: .ignore, keyPath: \.ignoreSystemNamedConstraintNames),
        Descriptor(name: "ignoreConstraintAndIndexNames", title: "Ignore all constraint and index names",
                   detail: "Keys, constraints and indexes are matched by what they do, not what they are called.",
                   group: .ignore, keyPath: \.ignoreConstraintAndIndexNames),
        Descriptor(name: "ignorePermissions", title: "Ignore permissions",
                   detail: "GRANT and DENY on objects are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignorePermissions),
        Descriptor(name: "ignoreUsersPermissionsAndRoleMemberships",
                   title: "Ignore users' permissions and role memberships",
                   detail: "Database-level permissions and role memberships of users and roles are ignored.",
                   group: .ignore, keyPath: \.ignoreUsersPermissionsAndRoleMemberships),
        Descriptor(name: "ignoreExtendedProperties", title: "Ignore extended properties",
                   detail: "MS_Description and other extended properties are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreExtendedProperties),
        Descriptor(name: "ignoreAuthorization", title: "Ignore authorization on schema objects",
                   detail: "Schema and object owners are not compared.",
                   group: .ignore, keyPath: \.ignoreAuthorization),
        Descriptor(name: "ignoreBindings", title: "Ignore bindings",
                   detail: "Columns bound to rules and defaults with sp_bindrule / sp_bindefault are not compared.",
                   group: .ignore, keyPath: \.ignoreBindings),
        Descriptor(name: "ignoreIndexes", title: "Ignore indexes",
                   detail: "Indexes, primary keys and unique constraints are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreIndexes),
        Descriptor(name: "ignorePerformanceIndexes", title: "Ignore performance indexes",
                   detail: "Non-unique nonclustered indexes are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignorePerformanceIndexes),
        Descriptor(name: "ignoreStatistics", title: "Ignore statistics",
                   detail: "User-created statistics are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreStatistics),
        Descriptor(name: "ignoreDMLTriggers", title: "Ignore DML triggers",
                   detail: "Triggers on tables and views are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreDMLTriggers),
        Descriptor(name: "ignoreTriggerOrder", title: "Ignore trigger order",
                   detail: "sp_settriggerorder First/Last settings are not compared.",
                   group: .ignore, keyPath: \.ignoreTriggerOrder),
        Descriptor(name: "ignoreCheckConstraints", title: "Ignore check constraints",
                   detail: "CHECK constraints are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreCheckConstraints),
        Descriptor(name: "ignoreForeignKeys", title: "Ignore foreign keys",
                   detail: "FOREIGN KEY constraints are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreForeignKeys),
        Descriptor(name: "ignoreFullTextIndexing", title: "Ignore full-text indexing",
                   detail: "Full-text indexes are neither compared nor scripted.",
                   group: .ignore, keyPath: \.ignoreFullTextIndexing),
        Descriptor(name: "ignoreLockProperties", title: "Ignore lock properties of indexes",
                   detail: "ALLOW_ROW_LOCKS and ALLOW_PAGE_LOCKS are not compared.",
                   group: .ignore, keyPath: \.ignoreLockProperties),
        Descriptor(name: "ignoreTableLockEscalation", title: "Ignore table lock escalation",
                   detail: "LOCK_ESCALATION is not compared.",
                   group: .ignore, keyPath: \.ignoreTableLockEscalation),
        Descriptor(name: "ignoreChangeTracking", title: "Ignore change tracking",
                   detail: "Whether change tracking is enabled on a table is not compared.",
                   group: .ignore, keyPath: \.ignoreChangeTracking),
        Descriptor(name: "ignoreDynamicDataMasking", title: "Ignore dynamic data masking",
                   detail: "MASKED WITH functions are not compared.",
                   group: .ignore, keyPath: \.ignoreDynamicDataMasking),
        Descriptor(name: "ignoreQuotedIdentifierAndAnsiNulls",
                   title: "Ignore SET QUOTED_IDENTIFIER and SET ANSI_NULLS",
                   detail: "The settings a module was created under are not compared.",
                   group: .ignore, keyPath: \.ignoreQuotedIdentifierAndAnsiNulls),
        Descriptor(name: "ignoreWithEncryption", title: "Ignore WITH ENCRYPTION",
                   detail: "Encrypted modules are treated as equal to each other instead of as unknown.",
                   group: .ignore, keyPath: \.ignoreWithEncryption),
        Descriptor(name: "ignoreSynonymDatabaseAndServerNames", title: "Ignore database and server name in synonyms",
                   detail: "Only the schema and object a synonym points at are compared.",
                   group: .ignore, keyPath: \.ignoreSynonymDatabaseAndServerNames),
        Descriptor(name: "ignoreSequenceStartValue", title: "Ignore sequence START WITH values",
                   detail: "A sequence's start value cannot be changed without resetting it, so it is not compared.",
                   group: .ignore, keyPath: \.ignoreSequenceStartValue),
        Descriptor(name: "ignoreSparseAndColumnSets", title: "Ignore SPARSE and column sets",
                   detail: "SPARSE columns and COLUMN_SET columns are compared as ordinary columns.",
                   group: .ignore, keyPath: \.ignoreSparseAndColumnSets),

        Descriptor(name: "forceColumnOrder", title: "Force column order",
                   detail: "A different column order is a difference, and tables are rebuilt to fix it. "
                   + "Otherwise new columns are added at the end.", group: .behavior,
                   keyPath: \.forceColumnOrder),
        Descriptor(name: "includeDependencies", title: "Include dependencies",
                   detail: "Deploying an object also deploys the missing or changed objects it needs.",
                   group: .behavior, keyPath: \.includeDependencies),
        Descriptor(name: "addObjectExistenceChecks", title: "Add object existence checks",
                   detail: "CREATE and DROP statements are guarded with IF EXISTS checks.",
                   group: .behavior, keyPath: \.addObjectExistenceChecks),
        Descriptor(name: "dropAndCreateInsteadOfAlter", title: "Drop and create instead of ALTER",
                   detail: "Changed views, procedures, functions and triggers are dropped and re-created.",
                   group: .behavior, keyPath: \.dropAndCreateInsteadOfAlter),
        Descriptor(name: "doNotUseTransactions", title: "Do not use transactions in deployment scripts",
                   detail: "The script runs without BEGIN TRANSACTION / COMMIT.",
                   group: .behavior, keyPath: \.doNotUseTransactions),
        Descriptor(name: "doNotAddErrorHandling", title: "Do not add error handling",
                   detail: "The @@ERROR / SET NOEXEC checks between batches are left out.",
                   group: .behavior, keyPath: \.doNotAddErrorHandling),
        Descriptor(name: "addDatabaseUseStatement", title: "Add database USE statement",
                   detail: "The script starts with USE [target database].",
                   group: .behavior, keyPath: \.addDatabaseUseStatement),
        Descriptor(name: "addOnlineOption", title: "Add ONLINE = ON option",
                   detail: "Index creation uses ONLINE = ON (Enterprise edition and Azure SQL only).",
                   group: .behavior, keyPath: \.addOnlineOption),
        Descriptor(name: "addSmartDefaults", title: "Add smart defaults for new NOT NULL columns",
                   detail: "A new NOT NULL column without a default gets a temporary one so existing "
                   + "rows can be filled.", group: .behavior, keyPath: \.addSmartDefaults),
        Descriptor(name: "renameMappedObjects", title: "Rename mapped tables and columns",
                   detail: "Objects and columns mapped under different names are renamed with sp_rename "
                   + "instead of being dropped and re-created.", group: .behavior,
                   keyPath: \.renameMappedObjects),
        Descriptor(name: "includePrintStatements", title: "Include PRINT statements",
                   detail: "The script reports each step as it runs.",
                   group: .behavior, keyPath: \.includePrintStatements),
        Descriptor(name: "refreshDependentViews", title: "Refresh dependent views",
                   detail: "Views over changed tables are refreshed with sp_refreshview.",
                   group: .behavior, keyPath: \.refreshDependentViews),
        Descriptor(name: "dropDependentForeignKeys", title: "Drop and re-create dependent foreign keys",
                   detail: "Foreign keys pointing at a table that has to be rebuilt or dropped are handled "
                   + "automatically.", group: .behavior, keyPath: \.dropDependentForeignKeys)
    ]

    public static func descriptor(named name: String) -> Descriptor? {
        descriptors.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Apply a comma-separated list such as `ignoreComments,-ignoreStatistics,+forceColumnOrder`.
    /// `default` resets everything first. Returns the names that were not recognised.
    @discardableResult
    public mutating func apply(list: String) -> [String] {
        var unknown: [String] = []
        for raw in list.split(separator: ",") {
            var item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if item.lowercased() == "default" {
                self = SchemaCompareOptions()
                continue
            }
            var value = true
            if item.hasPrefix("-") { value = false; item.removeFirst() }
            else if item.hasPrefix("+") { item.removeFirst() }
            guard let descriptor = SchemaCompareOptions.descriptor(named: item) else {
                unknown.append(item)
                continue
            }
            self[keyPath: descriptor.keyPath] = value
        }
        return unknown
    }

    /// Names of options that differ from the defaults, for reports.
    public var changedFromDefaults: [String] {
        let defaults = SchemaCompareOptions()
        return SchemaCompareOptions.descriptors.compactMap { descriptor in
            self[keyPath: descriptor.keyPath] == defaults[keyPath: descriptor.keyPath]
                ? nil : (self[keyPath: descriptor.keyPath] ? "+" : "-") + descriptor.name
        }
    }

    // Unknown keys in an older or newer project file must not make it unreadable.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: DynamicKey.self)
        for descriptor in SchemaCompareOptions.descriptors {
            if let key = DynamicKey(stringValue: descriptor.name),
               let value = try container.decodeIfPresent(Bool.self, forKey: key) {
                self[keyPath: descriptor.keyPath] = value
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for descriptor in SchemaCompareOptions.descriptors {
            if let key = DynamicKey(stringValue: descriptor.name) {
                try container.encode(self[keyPath: descriptor.keyPath], forKey: key)
            }
        }
    }
}

/// A coding key made from any string, for option sets addressed by name.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
