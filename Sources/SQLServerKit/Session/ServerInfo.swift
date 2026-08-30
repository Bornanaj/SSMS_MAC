import Foundation
import TDSKit

/// Everything the Object Explorer root node and the status bar need to show.
public struct ServerInfo: Sendable, Hashable, Codable {
    public var serverName: String = ""
    public var machineName: String = ""
    public var instanceName: String = ""
    public var productVersion: String = ""
    public var productLevel: String = ""
    public var productUpdateLevel: String = ""
    public var edition: String = ""
    public var engineEdition: Int = 0
    public var collation: String = ""
    public var loginName: String = ""
    public var isSysadmin: Bool = false
    public var currentDatabase: String = ""
    public var sessionID: Int = 0
    public var startTime: String = ""

    public var majorVersion: Int {
        Int(productVersion.split(separator: ".").first.map(String.init) ?? "0") ?? 0
    }

    public var minorVersion: Int {
        let parts = productVersion.split(separator: ".")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }

    public var isAzureSQLDatabase: Bool { engineEdition == 5 }
    public var isAzureManagedInstance: Bool { engineEdition == 8 }
    public var isAzureSynapse: Bool { engineEdition == 6 || engineEdition == 11 }
    public var isAzure: Bool { isAzureSQLDatabase || isAzureManagedInstance || isAzureSynapse }
    public var isAzureSQLEdge: Bool { engineEdition == 9 }

    /// "SQL Server 2022 (RTM-CU26)" style label used by the Object Explorer root.
    public var friendlyVersion: String {
        let product: String
        switch majorVersion {
        case 8: product = "SQL Server 2000"
        case 9: product = "SQL Server 2005"
        case 10: product = minorVersion >= 50 ? "SQL Server 2008 R2" : "SQL Server 2008"
        case 11: product = "SQL Server 2012"
        case 12: product = "SQL Server 2014"
        case 13: product = "SQL Server 2016"
        case 14: product = "SQL Server 2017"
        case 15: product = "SQL Server 2019"
        case 16: product = "SQL Server 2022"
        case 17: product = "SQL Server 2025"
        default: product = "SQL Server"
        }
        if isAzureSQLDatabase { return "Azure SQL Database" }
        if isAzureManagedInstance { return "Azure SQL Managed Instance" }
        if isAzureSynapse { return "Azure Synapse Analytics" }
        var text = product
        if !productLevel.isEmpty {
            var level = productLevel
            if !productUpdateLevel.isEmpty { level += "-\(productUpdateLevel)" }
            text += " (\(level))"
        }
        return text
    }

    /// What SSMS shows on the root node: `SERVER (SQL Server 16.0.4265 - sa)`.
    public var objectExplorerLabel: String {
        "\(serverName) (\(friendlyVersion.hasPrefix("SQL Server") ? "SQL Server" : friendlyVersion) "
            + "\(productVersion) - \(loginName))"
    }

    /// Supports features introduced in SQL Server 2016.
    public var supportsJSON: Bool { majorVersion >= 13 || isAzure }
    public var supportsTemporalTables: Bool { majorVersion >= 13 || isAzure }
    public var supportsStringAgg: Bool { majorVersion >= 14 || isAzure }
    public var supportsSequences: Bool { majorVersion >= 11 || isAzure }
    public var supportsResumableIndexes: Bool { majorVersion >= 14 || isAzure }
    public var supportsLedger: Bool { majorVersion >= 16 || isAzureSQLDatabase }
    public var supportsQueryStore: Bool { majorVersion >= 13 || isAzure }

    public static let query = """
    SELECT
        CAST(SERVERPROPERTY('ServerName') AS nvarchar(256))          AS ServerName,
        CAST(SERVERPROPERTY('MachineName') AS nvarchar(256))         AS MachineName,
        ISNULL(CAST(SERVERPROPERTY('InstanceName') AS nvarchar(256)), N'') AS InstanceName,
        CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))       AS ProductVersion,
        ISNULL(CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64)), N'')  AS ProductLevel,
        ISNULL(CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)), N'') AS ProductUpdateLevel,
        CAST(SERVERPROPERTY('Edition') AS nvarchar(256))             AS Edition,
        CAST(SERVERPROPERTY('EngineEdition') AS int)                 AS EngineEdition,
        CAST(SERVERPROPERTY('Collation') AS nvarchar(256))           AS Collation,
        SUSER_SNAME()                                                AS LoginName,
        CAST(ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0) AS int)         AS IsSysadmin,
        DB_NAME()                                                    AS CurrentDatabase,
        @@SPID                                                       AS SessionId
    """

    public init() {}

    public init(row: [String: TDSValue]) {
        func string(_ key: String) -> String {
            guard let value = row[key], !value.isNull else { return "" }
            return value.displayString(nullText: "")
        }
        func int(_ key: String) -> Int {
            guard let value = row[key] else { return 0 }
            if case .int(let i) = value { return Int(i) }
            return Int(value.displayString(nullText: "0")) ?? 0
        }
        serverName = string("ServerName")
        machineName = string("MachineName")
        instanceName = string("InstanceName")
        productVersion = string("ProductVersion")
        productLevel = string("ProductLevel")
        productUpdateLevel = string("ProductUpdateLevel")
        edition = string("Edition")
        engineEdition = int("EngineEdition")
        collation = string("Collation")
        loginName = string("LoginName")
        isSysadmin = int("IsSysadmin") == 1
        currentDatabase = string("CurrentDatabase")
        sessionID = int("SessionId")
    }
}

public extension TDSResultSet {
    /// Rows keyed by column name, which keeps catalog query parsing readable.
    func dictionaries() -> [[String: TDSValue]] {
        rows.map { row in
            var dict = [String: TDSValue]()
            for column in columns where column.index < row.count {
                dict[column.name] = row[column.index]
            }
            return dict
        }
    }
}

public extension Dictionary where Key == String, Value == TDSValue {
    func string(_ key: String, default fallback: String = "") -> String {
        guard let value = self[key], !value.isNull else { return fallback }
        if case .string(let s) = value { return s }
        return value.displayString(nullText: fallback)
    }

    func int(_ key: String, default fallback: Int = 0) -> Int {
        guard let value = self[key], !value.isNull else { return fallback }
        switch value {
        case .int(let i): return Int(i)
        case .bool(let b): return b ? 1 : 0
        case .decimal(let d): return Int(d.doubleValue)
        case .double(let d): return Int(d)
        case .float(let f): return Int(f)
        default: return Int(value.displayString(nullText: "")) ?? fallback
        }
    }

    func int64(_ key: String, default fallback: Int64 = 0) -> Int64 {
        guard let value = self[key], !value.isNull else { return fallback }
        switch value {
        case .int(let i): return i
        case .decimal(let d): return Int64(d.doubleValue)
        case .double(let d): return Int64(d)
        case .float(let f): return Int64(f)
        default: return Int64(value.displayString(nullText: "")) ?? fallback
        }
    }

    func double(_ key: String, default fallback: Double = 0) -> Double {
        guard let value = self[key], !value.isNull else { return fallback }
        switch value {
        case .int(let i): return Double(i)
        case .decimal(let d): return d.doubleValue
        case .double(let d): return d
        case .float(let f): return Double(f)
        default: return Double(value.displayString(nullText: "")) ?? fallback
        }
    }

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        guard let value = self[key], !value.isNull else { return fallback }
        switch value {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return int(key) != 0
        }
    }

    func isNull(_ key: String) -> Bool { self[key]?.isNull ?? true }
}
