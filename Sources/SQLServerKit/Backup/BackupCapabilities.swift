import Foundation
import TDSKit

/// What one server can do with backups. Probed once per connection; the wizards enable options
/// from it, so nothing is offered that the edition or version would reject.
public struct BackupServerCapabilities: Codable, Hashable, Sendable {
    public enum Platform: String, Codable, Sendable {
        case windows
        case linux
    }

    public var serverName: String = ""
    public var machineName: String = ""
    public var instanceName: String = ""
    public var majorVersion: Int = 0
    public var productVersion: String = ""
    public var engineEdition: Int = 0
    public var edition: String = ""
    public var platform: Platform = .windows
    public var defaultBackupFolder: String = ""
    public var defaultDataFolder: String = ""
    public var defaultLogFolder: String = ""
    public var isAgentRunning: Bool = false
    public var databaseMailEnabled: Bool = false
    public var compressionDefault: Bool = false
    public var checksumDefault: Bool = false
    /// `backup compression algorithm` (2022+): 0 = follow the default, 1 = MS_XPRESS, 2 = QAT, 3 = ZSTD.
    public var compressionAlgorithmSetting: Int = 0
    public var hasQAT: Bool = false
    public var isHadrEnabled: Bool = false
    public var isSysadmin: Bool = false
    public var serverTime: Date?

    public init() {}

    public var isExpress: Bool { engineEdition == 4 }
    public var isWeb: Bool { edition.lowercased().contains("web") }
    public var isAzureSQLDatabase: Bool { engineEdition == 5 }
    public var isManagedInstance: Bool { engineEdition == 8 }

    public var editionTitle: String {
        let name = edition.replacingOccurrences(of: " (64-bit)", with: "")
        return name.isEmpty ? "This edition" : "SQL Server \(name)"
    }

    /// Express and Web can restore compressed and encrypted backups but not create them.
    public var canCompress: Bool { !isExpress && !isWeb && majorVersion >= 10 }
    public var canEncrypt: Bool { !isExpress && !isWeb && majorVersion >= 12 }
    /// MIRROR TO is an Enterprise feature (Developer and Evaluation report the same engine edition).
    public var canMirror: Bool { engineEdition == 3 }
    public var supportsAlgorithmClause: Bool { majorVersion >= 16 }
    public var supportsZSTD: Bool { majorVersion >= 17 }
    public var supportsS3: Bool { majorVersion >= 16 }
    public var supportsAzureURL: Bool { majorVersion >= 12 || isManagedInstance }
    public var supportsFileExists: Bool { majorVersion >= 14 }
    public var supportsLastValidRestoreTime: Bool { majorVersion >= 16 }
    public var hasAgent: Bool { !isExpress && !isAzureSQLDatabase }
    public var canSchedule: Bool { hasAgent && isAgentRunning }
    public var canBackUp: Bool { !isAzureSQLDatabase }

    public var pathSeparator: String { platform == .linux ? "/" : "\\" }

    /// `<INSTANCE>`: the instance name, or `(local)` for a default instance.
    public var instanceTag: String { instanceName.isEmpty ? "(local)" : instanceName }

    public var backupFolder: String {
        defaultBackupFolder.isEmpty ? defaultDataFolder : defaultBackupFolder
    }

    // MARK: Compression

    /// The WITH clause for a compression level, or nil to leave compression to the server
    /// default (only when the edition cannot compress at all).
    public func compressionClause(level: Int) -> String? {
        guard canCompress else { return nil }
        if level <= 0 { return "NO_COMPRESSION" }
        if supportsZSTD {
            let strength: String = level <= 1 ? "LOW" : (level == 2 ? "MEDIUM" : "HIGH")
            return "COMPRESSION (ALGORITHM = ZSTD, LEVEL = \(strength))"
        }
        if supportsAlgorithmClause {
            // QAT offloads to hardware; the higher levels use it when it is actually there.
            if level >= 3 && hasQAT { return "COMPRESSION (ALGORITHM = QAT_DEFLATE)" }
            return "COMPRESSION (ALGORITHM = MS_XPRESS)"
        }
        return "COMPRESSION"
    }

    /// What a level means on this server, for the slider's caption.
    public func compressionDescription(level: Int) -> String {
        guard canCompress else { return "\(editionTitle) cannot create compressed backups" }
        if level <= 0 { return "No compression" }
        if supportsZSTD {
            let strength: String = level <= 1 ? "low" : (level == 2 ? "medium" : "high")
            return "ZSTD, \(strength) level"
        }
        if supportsAlgorithmClause && level >= 3 && hasQAT { return "Intel QAT (hardware DEFLATE)" }
        return "MS_XPRESS"
    }

    /// Why levels 1–4 all compress the same before SQL Server 2025.
    public var compressionNote: String? {
        guard canCompress, !supportsZSTD else { return nil }
        return "Before SQL Server 2025 native backups have one software algorithm (MS_XPRESS), so levels 1–4 "
            + "compress alike. SQL Server 2025 maps them to ZSTD low, medium and high."
    }

    /// Distinct levels this server actually distinguishes, so the analyzer does not run the
    /// same compression twice.
    public var distinctCompressionLevels: [Int] {
        guard canCompress else { return [0] }
        if supportsZSTD { return [0, 1, 2, 3] }
        if supportsAlgorithmClause && hasQAT { return [0, 1, 3] }
        return [0, 1]
    }

    // MARK: Paths

    public func join(_ folder: String, _ file: String) -> String {
        let trimmed = folder.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return file }
        if trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { return trimmed + file }
        return trimmed + pathSeparator + file
    }

    /// The folder part of a server path.
    public func folder(of path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return "" }
        return String(path[..<index])
    }

    public func fileName(of path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        return String(path[path.index(after: index)...])
    }
}

// MARK: - Probe

public struct BackupCapabilityProbe: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    public func probe() async throws -> BackupServerCapabilities {
        let info = await session.serverInfo
        var capabilities = BackupServerCapabilities()
        capabilities.serverName = info.serverName
        capabilities.machineName = info.machineName
        capabilities.instanceName = info.instanceName
        capabilities.productVersion = info.productVersion
        capabilities.majorVersion = info.majorVersion
        capabilities.engineEdition = info.engineEdition
        capabilities.edition = info.edition
        capabilities.isSysadmin = info.isSysadmin
        guard !info.isAzureSQLDatabase else { return capabilities }

        // Every property that an older version lacks comes back NULL rather than failing.
        let sql = """
        SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(512)) AS backup_path,
               CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512)) AS data_path,
               CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(512)) AS log_path,
               CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS int) AS hadr,
               SYSDATETIME() AS server_time;
        SELECT name, CAST(value_in_use AS int) AS value FROM sys.configurations
        WHERE name IN (N'backup compression default', N'backup checksum default',
                       N'backup compression algorithm', N'Database Mail XPs', N'Agent XPs');
        """
        let result = try await session.metadataQuery(sql, database: "master")
        let sets = result.resultSets
        if let row = sets.first?.dictionaries().first {
            capabilities.defaultBackupFolder = Self.trimSlash(row.string("backup_path"))
            capabilities.defaultDataFolder = Self.trimSlash(row.string("data_path"))
            capabilities.defaultLogFolder = Self.trimSlash(row.string("log_path"))
            capabilities.isHadrEnabled = row.int("hadr") == 1
            capabilities.serverTime = row.serverDate("server_time")
        }
        if sets.count > 1 {
            for row in sets[1].dictionaries() {
                let value = row.int("value")
                switch row.string("name").lowercased() {
                case "backup compression default": capabilities.compressionDefault = value == 1
                case "backup checksum default": capabilities.checksumDefault = value == 1
                case "backup compression algorithm": capabilities.compressionAlgorithmSetting = value
                case "database mail xps": capabilities.databaseMailEnabled = value == 1
                default: break
                }
            }
        }
        capabilities.platform = await platform(major: info.majorVersion)
        capabilities.isAgentRunning = await AgentService(session: session).isAgentRunning()
        if info.majorVersion >= 16 {
            capabilities.hasQAT = await acceleratorPresent()
        }
        if capabilities.defaultDataFolder.isEmpty {
            capabilities.defaultDataFolder = await masterFolder(fileID: 1)
        }
        if capabilities.defaultLogFolder.isEmpty {
            capabilities.defaultLogFolder = await masterFolder(fileID: 2)
        }
        if capabilities.defaultBackupFolder.isEmpty {
            capabilities.defaultBackupFolder = await registryBackupFolder()
        }
        return capabilities
    }

    private func platform(major: Int) async -> BackupServerCapabilities.Platform {
        guard major >= 14,
              let result = try? await session.metadataQuery("SELECT host_platform FROM sys.dm_os_host_info",
                                                           database: "master"),
              let row = result.resultSets.first?.dictionaries().first else { return .windows }
        return row.string("host_platform").lowercased().contains("linux") ? .linux : .windows
    }

    private func acceleratorPresent() async -> Bool {
        let sql = "SELECT COUNT(*) AS n FROM sys.dm_server_accelerator_status WHERE mode_desc <> N'NONE'"
        guard let result = try? await session.metadataQuery(sql, database: "master"),
              let row = result.resultSets.first?.dictionaries().first else { return false }
        return row.int("n") > 0
    }

    /// Before 2012 there is no InstanceDefaultDataPath; master's own files are the next best guess.
    private func masterFolder(fileID: Int) async -> String {
        let sql = "SELECT physical_name FROM sys.master_files WHERE database_id = 1 AND file_id = \(fileID)"
        guard let result = try? await session.metadataQuery(sql, database: "master"),
              let row = result.resultSets.first?.dictionaries().first else { return "" }
        let path = row.string("physical_name")
        guard let index = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return "" }
        return String(path[..<index])
    }

    /// The backup folder lived only in the registry before SQL Server 2019 added the property.
    private func registryBackupFolder() async -> String {
        let sql = """
        DECLARE @dir nvarchar(4000);
        EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
             N'Software\\Microsoft\\MSSQLServer\\MSSQLServer', N'BackupDirectory', @dir OUTPUT;
        SELECT @dir AS dir;
        """
        guard let result = try? await session.metadataQuery(sql, database: "master"),
              let row = result.resultSets.first?.dictionaries().first else { return "" }
        return Self.trimSlash(row.string("dir"))
    }

    static func trimSlash(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        while value.count > 1 && (value.hasSuffix("/") || value.hasSuffix("\\")) { value.removeLast() }
        return value
    }
}
