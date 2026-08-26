import Foundation
import TDSKit

public struct ConfigurationSetting: Sendable, Hashable, Identifiable {
    public var id: Int { configurationID }
    public var configurationID: Int
    public var name: String
    public var settingDescription: String
    public var configuredValue: String
    public var runningValue: String
    public var minimum: String
    public var maximum: String
    public var isDynamic: Bool
    public var isAdvanced: Bool

    /// True when the value has been set but needs RECONFIGURE or a restart.
    public var isPending: Bool { configuredValue != runningValue }

    /// Booleans in sp_configure are 0/1 with a 0..1 range.
    public var isBoolean: Bool { minimum == "0" && maximum == "1" }
}

public struct ServerPropertyGroup: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var entries: [(key: String, value: String)]

    public static func == (lhs: ServerPropertyGroup, rhs: ServerPropertyGroup) -> Bool {
        lhs.name == rhs.name && lhs.entries.map(\.key) == rhs.entries.map(\.key)
            && lhs.entries.map(\.value) == rhs.entries.map(\.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

public struct ServerConfiguration: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: Read

    public func settings() async throws -> [ConfigurationSetting] {
        let info = await session.serverInfo
        guard !info.isAzureSQLDatabase else {
            throw SQLServerError.unsupportedOperation(
                "sys.configurations is not exposed on Azure SQL Database.")
        }
        let sql = """
        SELECT configuration_id, name, ISNULL(description, N'') AS description,
               CAST(value AS nvarchar(40)) AS value,
               CAST(value_in_use AS nvarchar(40)) AS value_in_use,
               CAST(minimum AS nvarchar(40)) AS minimum,
               CAST(maximum AS nvarchar(40)) AS maximum,
               CAST(is_dynamic AS int) AS is_dynamic,
               CAST(is_advanced AS int) AS is_advanced
        FROM sys.configurations
        ORDER BY name
        """
        let result = try await session.metadataQuery(sql, database: "master")
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ConfigurationSetting(
                configurationID: row.int("configuration_id"),
                name: row.string("name"),
                settingDescription: row.string("description"),
                configuredValue: row.string("value"),
                runningValue: row.string("value_in_use"),
                minimum: row.string("minimum"),
                maximum: row.string("maximum"),
                isDynamic: row.int("is_dynamic") == 1,
                isAdvanced: row.int("is_advanced") == 1)
        }
    }

    /// The read-only pages of the SSMS server properties dialog.
    public func properties() async throws -> [ServerPropertyGroup] {
        let info = await session.serverInfo
        var groups: [ServerPropertyGroup] = []

        let generalSQL = """
        SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(200)) AS machine,
               CAST(SERVERPROPERTY('ServerName') AS nvarchar(200)) AS server_name,
               CAST(SERVERPROPERTY('Edition') AS nvarchar(200)) AS edition,
               CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(60)) AS version,
               CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(60)) AS level_name,
               CAST(SERVERPROPERTY('Collation') AS nvarchar(200)) AS collation,
               CAST(SERVERPROPERTY('IsClustered') AS int) AS is_clustered,
               CAST(SERVERPROPERTY('IsFullTextInstalled') AS int) AS fulltext,
               CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS windows_only,
               ISNULL(CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)), N'')
                   AS data_path,
               ISNULL(CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400)), N'')
                   AS log_path
        """
        if let row = try await first(generalSQL, database: "master") {
            groups.append(ServerPropertyGroup(name: "General", entries: [
                ("Name", row.string("server_name")),
                ("Machine", row.string("machine")),
                ("Edition", row.string("edition")),
                ("Version", row.string("version")),
                ("Product level", row.string("level_name")),
                ("Collation", row.string("collation")),
                ("Clustered", row.int("is_clustered") == 1 ? "Yes" : "No"),
                ("Full-text installed", row.int("fulltext") == 1 ? "Yes" : "No"),
                ("Authentication",
                 row.int("windows_only") == 1 ? "Windows only" : "SQL Server and Windows"),
                ("Default data path", row.string("data_path")),
                ("Default log path", row.string("log_path"))
            ]))
        }

        guard !info.isAzureSQLDatabase else { return groups }

        let hardwareSQL = """
        SELECT cpu_count, hyperthread_ratio, scheduler_count,
               CAST(physical_memory_kb / 1024 AS bigint) AS physical_memory_mb,
               CAST(committed_kb / 1024 AS bigint) AS committed_mb,
               CAST(committed_target_kb / 1024 AS bigint) AS target_mb,
               CONVERT(nvarchar(30), sqlserver_start_time, 120) AS start_time,
               ISNULL(CAST(SERVERPROPERTY('ProcessID') AS nvarchar(20)), N'') AS process_id
        FROM sys.dm_os_sys_info
        """
        if let row = try await first(hardwareSQL, database: "master") {
            groups.append(ServerPropertyGroup(name: "Hardware", entries: [
                ("Logical CPUs", "\(row.int("cpu_count"))"),
                ("Hyperthread ratio", "\(row.int("hyperthread_ratio"))"),
                ("Schedulers", "\(row.int("scheduler_count"))"),
                ("Physical memory", "\(row.int64("physical_memory_mb")) MB"),
                ("Committed memory", "\(row.int64("committed_mb")) MB"),
                ("Target memory", "\(row.int64("target_mb")) MB"),
                ("Started at", row.string("start_time")),
                ("Process id", row.string("process_id"))
            ]))
        }

        let servicesSQL = """
        SELECT servicename, ISNULL(startup_type_desc, N'') AS startup,
               ISNULL(status_desc, N'') AS status, ISNULL(service_account, N'') AS account
        FROM sys.dm_server_services
        """
        let services = try await rows(servicesSQL, database: "master")
        if !services.isEmpty {
            groups.append(ServerPropertyGroup(name: "Services", entries: services.map { row in
                (row.string("servicename"),
                 "\(row.string("status")) · \(row.string("startup")) · \(row.string("account"))")
            }))
        }

        return groups
    }

    // MARK: Write

    /// sp_configure needs "show advanced options" on before an advanced setting is
    /// reachable, and RECONFIGURE afterwards for the value to take effect.
    public func changeScript(setting: ConfigurationSetting, newValue: String) -> String {
        var lines: [String] = []
        if setting.isAdvanced {
            lines.append("EXEC sp_configure 'show advanced options', 1;")
            lines.append("RECONFIGURE;")
        }
        let name = setting.name.replacingOccurrences(of: "'", with: "''")
        lines.append("EXEC sp_configure '\(name)', \(newValue);")
        lines.append("RECONFIGURE\(setting.isDynamic ? "" : " WITH OVERRIDE");")
        if setting.isAdvanced {
            lines.append("EXEC sp_configure 'show advanced options', 0;")
            lines.append("RECONFIGURE;")
        }
        if !setting.isDynamic {
            lines.append("-- This option only takes effect after the service restarts.")
        }
        return lines.joined(separator: "\n")
    }

    public func apply(_ script: String) async throws {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        _ = try await connection.query(script)
    }

    // MARK: Helpers

    private func first(_ sql: String, database: String?) async throws -> [String: TDSValue]? {
        let result = try await session.metadataQuery(sql, database: database)
        return result.resultSets.first?.dictionaries().first
    }

    private func rows(_ sql: String, database: String?) async throws -> [[String: TDSValue]] {
        guard let result = try? await session.metadataQuery(sql, database: database) else {
            return []
        }
        return result.resultSets.first?.dictionaries() ?? []
    }
}
