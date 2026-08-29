import Foundation
import TDSKit

// MARK: - Models

/// The Server Properties dialog: General, Memory, Processors, Security, Database Settings
/// and Advanced, collapsed into one value type.
public struct ServerProperties: Sendable, Hashable {
    public var name: String
    public var machineName: String
    public var instanceName: String
    public var product: String
    public var version: String
    public var friendlyVersion: String
    public var productLevel: String
    public var edition: String
    public var collation: String
    public var language: String
    public var isClustered: Bool
    public var isHadrEnabled: Bool
    public var isFullTextInstalled: Bool
    /// `true` when the instance only accepts Windows logins.
    public var isWindowsAuthenticationOnly: Bool
    public var rootDirectory: String
    public var defaultDataPath: String
    public var defaultLogPath: String
    public var defaultBackupPath: String
    public var startTime: String
    public var uptimeText: String

    public var processorCount: Int
    public var schedulerCount: Int
    public var hyperthreadRatio: Int
    public var socketCount: Int
    public var physicalMemoryMB: Int64
    public var virtualMachineType: String

    public var minServerMemoryMB: Int
    public var maxServerMemoryMB: Int
    public var maxDegreeOfParallelism: Int
    public var costThresholdForParallelism: Int
    public var maxWorkerThreads: Int
    public var userConnectionLimit: Int
    public var remoteQueryTimeoutSeconds: Int
    public var isRemoteAdminConnectionsEnabled: Bool
    public var isBackupCompressionDefault: Bool
    public var isOptimizeForAdHocWorkloads: Bool

    public init(name: String = "",
                machineName: String = "",
                instanceName: String = "",
                product: String = "",
                version: String = "",
                friendlyVersion: String = "",
                productLevel: String = "",
                edition: String = "",
                collation: String = "",
                language: String = "",
                isClustered: Bool = false,
                isHadrEnabled: Bool = false,
                isFullTextInstalled: Bool = false,
                isWindowsAuthenticationOnly: Bool = false,
                rootDirectory: String = "",
                defaultDataPath: String = "",
                defaultLogPath: String = "",
                defaultBackupPath: String = "",
                startTime: String = "",
                uptimeText: String = "",
                processorCount: Int = 0,
                schedulerCount: Int = 0,
                hyperthreadRatio: Int = 0,
                socketCount: Int = 0,
                physicalMemoryMB: Int64 = 0,
                virtualMachineType: String = "",
                minServerMemoryMB: Int = 0,
                maxServerMemoryMB: Int = 0,
                maxDegreeOfParallelism: Int = 0,
                costThresholdForParallelism: Int = 0,
                maxWorkerThreads: Int = 0,
                userConnectionLimit: Int = 0,
                remoteQueryTimeoutSeconds: Int = 0,
                isRemoteAdminConnectionsEnabled: Bool = false,
                isBackupCompressionDefault: Bool = false,
                isOptimizeForAdHocWorkloads: Bool = false) {
        self.name = name
        self.machineName = machineName
        self.instanceName = instanceName
        self.product = product
        self.version = version
        self.friendlyVersion = friendlyVersion
        self.productLevel = productLevel
        self.edition = edition
        self.collation = collation
        self.language = language
        self.isClustered = isClustered
        self.isHadrEnabled = isHadrEnabled
        self.isFullTextInstalled = isFullTextInstalled
        self.isWindowsAuthenticationOnly = isWindowsAuthenticationOnly
        self.rootDirectory = rootDirectory
        self.defaultDataPath = defaultDataPath
        self.defaultLogPath = defaultLogPath
        self.defaultBackupPath = defaultBackupPath
        self.startTime = startTime
        self.uptimeText = uptimeText
        self.processorCount = processorCount
        self.schedulerCount = schedulerCount
        self.hyperthreadRatio = hyperthreadRatio
        self.socketCount = socketCount
        self.physicalMemoryMB = physicalMemoryMB
        self.virtualMachineType = virtualMachineType
        self.minServerMemoryMB = minServerMemoryMB
        self.maxServerMemoryMB = maxServerMemoryMB
        self.maxDegreeOfParallelism = maxDegreeOfParallelism
        self.costThresholdForParallelism = costThresholdForParallelism
        self.maxWorkerThreads = maxWorkerThreads
        self.userConnectionLimit = userConnectionLimit
        self.remoteQueryTimeoutSeconds = remoteQueryTimeoutSeconds
        self.isRemoteAdminConnectionsEnabled = isRemoteAdminConnectionsEnabled
        self.isBackupCompressionDefault = isBackupCompressionDefault
        self.isOptimizeForAdHocWorkloads = isOptimizeForAdHocWorkloads
    }

    /// "Windows Authentication mode" / "SQL Server and Windows Authentication mode",
    /// worded the way the Security page words it.
    public var authenticationMode: String {
        isWindowsAuthenticationOnly
            ? "Windows Authentication mode"
            : "SQL Server and Windows Authentication mode"
    }
}

/// One row of `sys.configurations` — the Advanced page and `sp_configure` both use it.
public struct ServerConfiguration: Sendable, Hashable, Identifiable {
    public var id: Int { configurationID }

    public var configurationID: Int
    public var name: String
    /// The configured value. It only takes effect after RECONFIGURE.
    public var value: Int64
    public var valueInUse: Int64
    public var minimum: Int64
    public var maximum: Int64
    public var isDynamic: Bool
    public var isAdvanced: Bool
    public var configurationDescription: String

    public init(configurationID: Int = 0,
                name: String = "",
                value: Int64 = 0,
                valueInUse: Int64 = 0,
                minimum: Int64 = 0,
                maximum: Int64 = 0,
                isDynamic: Bool = false,
                isAdvanced: Bool = false,
                configurationDescription: String = "") {
        self.configurationID = configurationID
        self.name = name
        self.value = value
        self.valueInUse = valueInUse
        self.minimum = minimum
        self.maximum = maximum
        self.isDynamic = isDynamic
        self.isAdvanced = isAdvanced
        self.configurationDescription = configurationDescription
    }

    /// A pending change is one where the configured value has not been reconfigured in.
    public var needsRestart: Bool { value != valueInUse && !isDynamic }
    public var isPending: Bool { value != valueInUse }
}

// MARK: - Server administration

/// The server-scoped half of SSMS's administration surface: the Server Properties
/// dialog and the `sp_configure` settings behind its Advanced page.
public struct ServerAdmin: Sendable {

    private let session: SQLServerSession
    private let runner: AdminRunner

    public init(session: SQLServerSession) {
        self.session = session
        self.runner = AdminRunner(session: session)
    }

    // MARK: Properties

    public func properties() async throws -> ServerProperties {
        let info = await session.serverInfo
        var properties = ServerProperties(
            name: info.serverName,
            machineName: info.machineName,
            instanceName: info.instanceName,
            product: "Microsoft SQL Server",
            version: info.productVersion,
            friendlyVersion: info.friendlyVersion,
            productLevel: info.productLevel,
            edition: info.edition,
            collation: info.collation
        )

        // SERVERPROPERTY answers NULL for anything the edition does not have, and the
        // path properties only exist from 2012 (data/log) and 2019 (backup) onwards.
        let headerSQL = """
        SELECT
            ISNULL(CONVERT(nvarchar(256), SERVERPROPERTY('Collation')), N'')                AS Collation,
            ISNULL(CONVERT(int, SERVERPROPERTY('IsClustered')), 0)                          AS IsClustered,
            ISNULL(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), 0)                        AS IsHadrEnabled,
            ISNULL(CONVERT(int, SERVERPROPERTY('IsFullTextInstalled')), 0)                  AS IsFullText,
            ISNULL(CONVERT(int, SERVERPROPERTY('IsIntegratedSecurityOnly')), 0)             AS IsWindowsOnly,
            ISNULL(CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultDataPath')), N'')  AS DataPath,
            ISNULL(CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultLogPath')), N'')   AS LogPath,
            ISNULL(CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultBackupPath')), N'') AS BackupPath,
            ISNULL(CONVERT(nvarchar(256), SERVERPROPERTY('ProductVersion')), N'')           AS ProductVersion,
            ISNULL(CONVERT(nvarchar(128), @@LANGUAGE), N'')                                 AS ServerLanguage;
        """
        if let row = try await runner.read(headerSQL, database: runner.serverScope(info)).first {
            if properties.collation.isEmpty { properties.collation = row.string("Collation") }
            properties.isClustered = row.bool("IsClustered")
            properties.isHadrEnabled = row.bool("IsHadrEnabled")
            properties.isFullTextInstalled = row.bool("IsFullText")
            properties.isWindowsAuthenticationOnly = row.bool("IsWindowsOnly")
            properties.defaultDataPath = row.string("DataPath")
            properties.defaultLogPath = row.string("LogPath")
            properties.defaultBackupPath = row.string("BackupPath")
            properties.language = row.string("ServerLanguage")
            if properties.version.isEmpty { properties.version = row.string("ProductVersion") }
        }

        // sys.dm_os_sys_info and sys.configurations are both unreachable on Azure SQL
        // Database; the header above is all that dialog can show there.
        guard !info.isAzureSQLDatabase else { return properties }

        let hardwareSQL = """
        SELECT
            CAST(si.cpu_count AS int)                                       AS CpuCount,
            CAST(si.scheduler_count AS int)                                 AS SchedulerCount,
            CAST(si.hyperthread_ratio AS int)                               AS HyperthreadRatio,
            CAST(ISNULL(si.socket_count, 0) AS int)                         AS SocketCount,
            CAST(si.physical_memory_kb / 1024 AS bigint)                    AS PhysicalMemoryMB,
            ISNULL(si.virtual_machine_type_desc, N'')                       AS VirtualMachineType,
            ISNULL(CONVERT(nvarchar(23), si.sqlserver_start_time, 121), N'') AS StartTime,
            CAST(DATEDIFF(minute, si.sqlserver_start_time, SYSDATETIME()) AS bigint) AS UptimeMinutes
        FROM sys.dm_os_sys_info AS si;
        """
        if let row = (try? await runner.read(hardwareSQL, database: "master"))?.first {
            properties.processorCount = row.int("CpuCount")
            properties.schedulerCount = row.int("SchedulerCount")
            properties.hyperthreadRatio = row.int("HyperthreadRatio")
            properties.socketCount = row.int("SocketCount")
            properties.physicalMemoryMB = row.int64("PhysicalMemoryMB")
            properties.virtualMachineType = row.string("VirtualMachineType")
            properties.startTime = row.string("StartTime")
            properties.uptimeText = ServerAdmin.uptimeText(minutes: row.int64("UptimeMinutes"))
        }
        if properties.startTime.isEmpty { properties.startTime = info.startTime }

        if let configurations = try? await self.configurations() {
            let byName = Dictionary(configurations.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            func value(_ name: String) -> Int64 { byName[name]?.valueInUse ?? 0 }
            properties.minServerMemoryMB = Int(value("min server memory (MB)"))
            properties.maxServerMemoryMB = Int(value("max server memory (MB)"))
            properties.maxDegreeOfParallelism = Int(value("max degree of parallelism"))
            properties.costThresholdForParallelism = Int(value("cost threshold for parallelism"))
            properties.maxWorkerThreads = Int(value("max worker threads"))
            properties.userConnectionLimit = Int(value("user connections"))
            properties.remoteQueryTimeoutSeconds = Int(value("remote query timeout (s)"))
            properties.isRemoteAdminConnectionsEnabled = value("remote admin connections") != 0
            properties.isBackupCompressionDefault = value("backup compression default") != 0
            properties.isOptimizeForAdHocWorkloads = value("optimize for ad hoc workloads") != 0
        }

        // The root directory only lives in the registry; xp_instance_regread needs
        // sysadmin, so a plain user simply gets no value here.
        if info.isSysadmin {
            properties.rootDirectory = (try? await rootDirectory()) ?? ""
        }

        return properties
    }

    private func rootDirectory() async throws -> String {
        let sql = """
        DECLARE @path nvarchar(512);
        EXEC master.dbo.xp_instance_regread
            N'HKEY_LOCAL_MACHINE', N'Software\\Microsoft\\MSSQLServer\\Setup',
            N'SQLPath', @path OUTPUT;
        SELECT ISNULL(@path, N'') AS RootDirectory;
        """
        return try await runner.read(sql, database: "master").first?.string("RootDirectory") ?? ""
    }

    // MARK: Configuration

    public func configurations() async throws -> [ServerConfiguration] {
        try await runner.requireBoxProduct("sp_configure")
        let sql = """
        SELECT
            CAST(c.configuration_id AS int)              AS ConfigurationId,
            c.name                                       AS ConfigurationName,
            CAST(c.value AS bigint)                      AS ConfiguredValue,
            CAST(c.value_in_use AS bigint)               AS ValueInUse,
            CAST(c.minimum AS bigint)                    AS MinimumValue,
            CAST(c.maximum AS bigint)                    AS MaximumValue,
            CAST(c.is_dynamic AS int)                    AS IsDynamic,
            CAST(c.is_advanced AS int)                   AS IsAdvanced,
            ISNULL(c.description, N'')                   AS ConfigurationDescription
        FROM sys.configurations AS c
        ORDER BY c.name;
        """
        return try await runner.read(sql, database: "master").map { row in
            ServerConfiguration(
                configurationID: row.int("ConfigurationId"),
                name: row.string("ConfigurationName"),
                value: row.int64("ConfiguredValue"),
                valueInUse: row.int64("ValueInUse"),
                minimum: row.int64("MinimumValue"),
                maximum: row.int64("MaximumValue"),
                isDynamic: row.bool("IsDynamic"),
                isAdvanced: row.bool("IsAdvanced"),
                configurationDescription: row.string("ConfigurationDescription")
            )
        }
    }

    /// `sp_configure` takes the option name as a string, so it has to be validated
    /// against `sys.configurations` before it goes into a statement. The value is an
    /// integer, so it can only ever be a number.
    public func setConfiguration(name: String, value: Int64) async throws -> [String] {
        try await runner.requireBoxProduct("sp_configure")
        let options = try await configurations()
        guard let option = options.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else {
            throw SQLServerError.objectNotFound("Server configuration option '\(name)'")
        }
        guard value >= option.minimum, value <= option.maximum else {
            throw SQLServerError.unsupportedOperation(
                "\(option.name) accepts \(option.minimum)–\(option.maximum); \(value) is out of range.")
        }

        var statements = ""
        // Advanced options are invisible to sp_configure until show advanced options is on.
        if option.isAdvanced {
            statements += "EXEC sys.sp_configure N'show advanced options', 1;\nRECONFIGURE;\n"
        }
        statements += "EXEC sys.sp_configure \(SQLIdentifier.literal(option.name)), \(value);\n"
        statements += "RECONFIGURE;\n"

        var lines = try await runner.runCollectingMessages(statements, database: "master")
        if option.needsRestart {
            lines.append("\(option.name) is not a dynamic option; the change takes effect "
                + "after the instance restarts.")
        }
        return lines
    }

    /// The script SSMS puts behind the Script button of the Server Properties dialog.
    public func configurationScript(name: String, value: Int64) -> String {
        "EXEC sys.sp_configure N'show advanced options', 1;\nGO\nRECONFIGURE;\nGO\n"
            + "EXEC sys.sp_configure \(SQLIdentifier.literal(name)), \(value);\nGO\nRECONFIGURE;\nGO\n"
    }

    // MARK: Formatting

    /// "12 days 4 hours" — the shape the General page uses for uptime.
    public static func uptimeText(minutes: Int64) -> String {
        guard minutes > 0 else { return "" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if days == 0 && remainder > 0 {
            parts.append("\(remainder) minute\(remainder == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "less than a minute" : parts.joined(separator: " ")
    }
}
