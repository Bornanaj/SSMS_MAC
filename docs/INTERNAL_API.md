# Internal API contract (read before writing any code)

Swift 6 toolchain, language mode 5. macOS 14+. Targets:

- `TDSKit` – pure Swift TDS 7.4 driver (already complete, do not modify).
- `SQLServerKit` – depends on TDSKit (this is where new service code goes).
- `SSMSMac` – SwiftUI app.

## TDSKit surface you may use

```swift
public enum TDSValue: Sendable, Hashable {
    case null, bool(Bool), int(Int64), double(Double), float(Float)
    case decimal(TDSDecimal), string(String), binary([UInt8]), uuid(UUID)
    case temporal(TDSTemporal), xml(String)
    public var isNull: Bool { get }
    public func displayString(nullText: String = "NULL") -> String
    public var sqlLiteral: String { get }
}

public struct TDSColumn: Sendable, Hashable {
    public var index: Int
    public var name: String
    public var typeInfo: TDSTypeInfo
    public var nullable: Bool
    public var identity: Bool
    public var computed: Bool
    public var updatable: Int      // 0 read-only, 1 read/write, 2 unknown
    public var hidden: Bool
    public var sqlTypeName: String // "nvarchar(50)"
    public var isReadOnly: Bool
}

public struct TDSResultSet: Sendable { public var columns: [TDSColumn]; public var rows: [[TDSValue]] }
public struct TDSQueryResult: Sendable {
    public var resultSets: [TDSResultSet]
    public var messages: [TDSServerMessage]
    public var errors: [TDSServerMessage]
    public var rowsAffected: [Int64]
}
public final class TDSConnection {
    public func query(_ sql: String) async throws -> TDSQueryResult
    public func execute(_ sql: String, resetConnection: Bool = false,
                        sink: @escaping @Sendable (TDSStreamEvent) -> Void) async throws
    public func scalar(_ sql: String) async throws -> TDSValue?
    public func cancel()
    public var database: String { get }
}
public struct TDSServerMessage: Error, Sendable, Hashable, Codable {
    public var number: Int32; public var state: UInt8; public var severity: UInt8
    public var text: String; public var procedureName: String; public var lineNumber: Int32
    public var formatted: String { get }
}
```

## SQLServerKit surface that already exists

```swift
public actor SQLServerSession: Identifiable {
    public nonisolated let id: UUID
    public nonisolated let profile: ConnectionProfile
    public private(set) var serverInfo: ServerInfo
    public func openConnection(database: String? = nil) async throws -> TDSConnection
    @discardableResult
    public func metadataQuery(_ sql: String, database: String? = nil) async throws -> TDSQueryResult
    public func refreshServerInfo() async throws
    public func close() async
}

public struct ServerInfo: Sendable, Hashable, Codable {
    public var serverName, machineName, instanceName: String
    public var productVersion, productLevel, productUpdateLevel, edition, collation, loginName: String
    public var engineEdition: Int
    public var isSysadmin: Bool
    public var currentDatabase: String
    public var majorVersion: Int { get }       // 16 == SQL Server 2022
    public var isAzureSQLDatabase: Bool { get }
    public var isAzure: Bool { get }
    public var friendlyVersion: String { get }
    public var supportsTemporalTables: Bool { get }
    public var supportsSequences: Bool { get }
    public var supportsLedger: Bool { get }
}

public enum SQLIdentifier {
    public static func quote(_ name: String) -> String                       // [name]
    public static func quote(schema: String, name: String) -> String         // [s].[n]
    public static func quote(database: String, schema: String, name: String) -> String
    public static func literal(_ value: String) -> String                    // N'...'
    public static func isRegular(_ name: String) -> Bool
}

public enum SQLServerError: Error, CustomStringConvertible {
    case invalidProfile(String), notConnected, objectNotFound(String)
    case unsupportedOperation(String), cancelled
}

// Row helpers – use these instead of hand-rolling TDSValue unwrapping.
public extension TDSResultSet { func dictionaries() -> [[String: TDSValue]] }
public extension Dictionary where Key == String, Value == TDSValue {
    func string(_ key: String, default: String = "") -> String
    func int(_ key: String, default: Int = 0) -> Int
    func int64(_ key: String, default: Int64 = 0) -> Int64
    func double(_ key: String, default: Double = 0) -> Double
    func bool(_ key: String, default: Bool = false) -> Bool
    func isNull(_ key: String) -> Bool
}

// Query pipeline (already written)
public enum BatchSplitter { public static func split(_ script: String) -> [SQLBatch] }
public struct TSQLLexer { public func tokenize(_ source: String) -> [TSQLToken] }
public enum TSQLKeywords { public static let reserved, dataTypes, functions: Set<String> }
public final class QueryExecutor { /* execute(script:options:onEvent:) */ }
public struct QueryExecutionOptions, QuerySetOptions, SQLMessage, ResultSetHandle, QueryExecutionSummary
public enum QueryEvent
```

## House rules

1. Swift 6 toolchain in language mode 5. Do **not** add `@preconcurrency`, actors, or
   `Sendable` conformances unless the type genuinely crosses isolation boundaries.
2. Public types get doc comments only where the intent is not obvious from the name.
   Do not narrate every line.
3. No new SwiftPM dependencies. Foundation only (plus TDSKit).
4. Every catalog query must work on SQL Server 2016 through 2022 **and** Azure SQL
   Database. Guard version-specific columns with `ServerInfo.majorVersion` checks or
   `OBJECT_ID('sys.x') IS NOT NULL` style probes rather than failing outright.
5. Always schema-qualify with `sys.` and quote identifiers through `SQLIdentifier`.
6. Never interpolate a user string into SQL without `SQLIdentifier.quote` or
   `SQLIdentifier.literal`.
7. Match the existing file style: 4 space indent, ~110 column soft wrap,
   `// MARK: -` section headers in long files.
8. Do NOT run `swift build` – several agents share this checkout and would collide.
   Write correct code and stop.
9. Only create the files listed in your task. Never edit files owned by another task.

## Object Explorer node model (already written – use as-is, do not redefine)

`Sources/SQLServerKit/Metadata/ObjectExplorerNode.swift` defines:

- `enum ObjectNodeKind` – server, folder, database, table, view, column, index,
  primaryKey, uniqueKey, foreignKey, checkConstraint, defaultConstraint, trigger,
  storedProcedure, scalarFunction, tableValuedFunction, aggregateFunction, synonym,
  sequence, userDefinedDataType, userDefinedTableType, schema, databaseUser,
  databaseRole, applicationRole, login, serverRole, credential, linkedServer,
  filegroup, databaseFile, parameter, statistic, assembly, xmlSchemaCollection,
  partitionFunction, partitionScheme, agentJob, availabilityGroup, availabilityReplica,
  availabilityDatabase, availabilityListener, externalTable, securityPolicy, unknown
- `enum ObjectFolderKind` – databases, systemDatabases, tables, systemTables, views,
  systemViews, columns, keys, constraints, indexes, triggers, statistics,
  programmability, storedProcedures, systemStoredProcedures, functions,
  tableValuedFunctions, scalarValuedFunctions, aggregateFunctions, systemFunctions,
  types, userDefinedDataTypes, userDefinedTableTypes, sequences, synonyms, security,
  databaseUsers, databaseRoles, applicationRoles, schemas, serverObjects, logins,
  serverRoles, credentials, linkedServers, management, agent, agentJobs, storage,
  filegroups, databaseFiles, parameters, assemblies, xmlSchemaCollections,
  partitionSchemes, partitionFunctions, securityPolicies, alwaysOn, availabilityGroups,
  availabilityReplicas, availabilityDatabases, availabilityListeners,
  and more (see the file)
- `struct ObjectExplorerNode: Identifiable, Hashable, Sendable` with
  `id, parentID, kind, folder, label, detail, iconName, isExpandable, database,
   schema, name, objectID, isSystemObject, info: [String: String]`
  plus `qualifiedName`, `displayPath`, `isTableLike`, `isModule`
- `struct ObjectExplorerOptions` with `showSystemObjects, nameFilter, maxChildren`

Node ids are path strings: `"<sessionUUID>/db:AdventureWorks/folder:tables/table:dbo.Person"`.
Build them with a helper in your own file; keep them stable across refreshes.

## Multi-instance script plans

Availability group work spans instances, so SQLServerKit carries a plan type rather
than assuming one connection:

```swift
public struct ScriptStep: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var instance: String        // the engine's name for the target replica
    public var database: String        // "master" unless the statement needs otherwise
    public var script: String
    public var detail: String
    public var continuesOnFailure: Bool
    public var isReadOnly: Bool
}

public struct ScriptPlan: Sendable, Hashable {
    public var title: String
    public var summary: String
    public var steps: [ScriptStep]
    public var outcomes: [UUID: ScriptStepOutcome]
    public var stopsOnFailure: Bool
    public var instances: [String]              // distinct, in the order needed
    public func nextRunnableIndex() -> Int?
    public func state(of: ScriptStep) -> ScriptStepState
    public mutating func record(_: ScriptStepOutcome, for: ScriptStep)
}

public enum ScriptStepRunner {
    public static func run(_ step: ScriptStep, on session: SQLServerSession) async
        -> ScriptStepOutcome
}

public enum AvailabilityGroupPlans {
    public static func failover(group:target:replicas:databases:allowDataLoss:) throws -> ScriptPlan
    public static func addReplica(group:replica:supportsSeeding:) throws -> ScriptPlan
    public static func addDatabases(group:databases:replicas:) throws -> ScriptPlan
    public static func resumeEverywhere(group:databases:) throws -> ScriptPlan
}
```

Sequencing is the caller's: the runner executes one step on one session, and the app's
`ScriptPlanSheet` decides whether to take the next one. `ReplicaConnectionBroker`
(SSMSMac) resolves a step's instance to a session — reusing one the app already holds,
otherwise connecting with the credentials of the connection the plan came from — and
closes only the sessions it opened itself.
