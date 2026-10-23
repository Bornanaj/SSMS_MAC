import Foundation
import TDSKit

// MARK: - Server folders

/// A file or folder on the SQL Server machine. Backup paths are resolved by the server, so the
/// wizards browse the server's file system through the server, not the Mac's.
public struct ServerFileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?

    public var isBackupFile: Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".bak") || lower.hasSuffix(".trn") || lower.hasSuffix(".dif")
            || lower.hasSuffix(".diff") || lower.hasSuffix(".log") || lower.hasSuffix(".sqb")
    }
}

public struct ServerFileBrowser: Sendable {
    private let session: SQLServerSession
    private let capabilities: BackupServerCapabilities

    public init(session: SQLServerSession, capabilities: BackupServerCapabilities) {
        self.session = session
        self.capabilities = capabilities
    }

    /// Starting points: the drives on Windows, `/` on Linux, plus the server's default folders.
    public func roots() async -> [ServerFileEntry] {
        var roots: [ServerFileEntry] = []
        for folder in [capabilities.backupFolder, capabilities.defaultDataFolder] where !folder.isEmpty {
            roots.append(ServerFileEntry(name: folder, path: folder, isDirectory: true, size: 0, modified: nil))
        }
        if capabilities.platform == .linux {
            roots.append(ServerFileEntry(name: "/", path: "/", isDirectory: true, size: 0, modified: nil))
        } else if let result = try? await session.metadataQuery("EXEC master.dbo.xp_fixeddrives", database: "master") {
            for row in result.resultSets.first?.dictionaries() ?? [] {
                let drive = row.string("drive") + ":\\"
                roots.append(ServerFileEntry(name: drive, path: drive, isDirectory: true, size: 0, modified: nil))
            }
        }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.path.lowercased()).inserted }
    }

    public func list(_ folder: String) async throws -> [ServerFileEntry] {
        let base = folder.hasSuffix("/") || folder.hasSuffix("\\") ? folder : folder + capabilities.pathSeparator
        if capabilities.majorVersion >= 14 {
            let sql = """
            SELECT file_or_directory_name AS name, CAST(is_directory AS int) AS is_directory,
                   CAST(size_in_bytes AS bigint) AS size, last_write_time
            FROM sys.dm_os_enumerate_filesystem(\(SQLIdentifier.literal(base)), N'*')
            WHERE level = 0;
            """
            let result = try await session.metadataQuery(sql, database: "master")
            return sorted((result.resultSets.first?.dictionaries() ?? []).map { row in
                let name = row.string("name")
                return ServerFileEntry(name: name, path: base + name, isDirectory: row.int("is_directory") == 1,
                                       size: row.int64("size"), modified: row.serverDate("last_write_time"))
            })
        }
        let result = try await session.metadataQuery(
            "EXEC master.dbo.xp_dirtree \(SQLIdentifier.literal(base)), 1, 1;", database: "master")
        return sorted((result.resultSets.first?.dictionaries() ?? []).map { row in
            let name = row.string("subdirectory")
            return ServerFileEntry(name: name, path: base + name, isDirectory: row.int("file") == 0, size: 0, modified: nil)
        })
    }

    private func sorted(_ entries: [ServerFileEntry]) -> [ServerFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func createFolder(_ path: String) async throws {
        _ = try await session.metadataQuery("EXEC master.dbo.xp_create_subdir \(SQLIdentifier.literal(path));",
                                            database: "master")
    }

    public func fileExists(_ path: String) async throws -> Bool {
        let sql = "DECLARE @e int = 0; EXEC master.dbo.xp_fileexist \(SQLIdentifier.literal(path)), @e OUTPUT; SELECT @e AS e;"
        let result = try await session.metadataQuery(sql, database: "master")
        return result.resultSets.first?.dictionaries().first?.int("e") == 1
    }

    /// Checks the server's service account can write to and read from a folder: a tiny copy-only
    /// backup of model, verified, then deleted (SQL Backup's folder permission check).
    public func testFolder(_ folder: String) async throws -> String {
        let probe = capabilities.join(folder, "ssmsmac_permission_check_\(UUID().uuidString.prefix(8)).bak")
        let sql = """
        EXEC master.dbo.xp_create_subdir \(SQLIdentifier.literal(folder));
        BACKUP DATABASE [model] TO DISK = \(SQLIdentifier.literal(probe)) WITH COPY_ONLY, FORMAT, INIT, NAME = N'Folder check';
        RESTORE VERIFYONLY FROM DISK = \(SQLIdentifier.literal(probe));
        EXEC master.dbo.xp_delete_file 0, \(SQLIdentifier.literal(probe));
        """
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        _ = try await StreamingStatement.run(sql, on: connection)
        return "SQL Server can create, read and delete backup files in \(folder)."
    }
}

// MARK: - Certificates

/// A certificate in master that can encrypt backups.
public struct BackupCertificate: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var subject: String
    public var expiry: Date?
    public var thumbprint: String
    public var hasPrivateKey: Bool
    /// When the private key was last exported; nil means never, so backups encrypted with it
    /// could not be restored anywhere else if this server were lost.
    public var privateKeyLastBackedUp: Date?
}

/// A certificate with its private key, exported so encrypted backups can be restored on
/// another server. The private key stays encrypted by the export password.
public struct BackupCertificateBundle: Codable, Sendable {
    public var name: String
    public var certificate: Data
    public var privateKey: Data
    public var exportedFrom: String
    public var exportedAt: Date

    public static let fileExtension = "sqlcert"
}

public struct BackupEncryptionKeys: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    public func certificates() async throws -> [BackupCertificate] {
        let major = await session.serverInfo.majorVersion
        let lastBackup = major >= 11 ? "pvt_key_last_backup_date" : "CAST(NULL AS datetime)"
        let sql = """
        SELECT name, subject, expiry_date, CONVERT(varchar(100), thumbprint, 2) AS thumbprint,
               CASE WHEN pvt_key_encryption_type IN ('MK', 'PW') THEN 1 ELSE 0 END AS has_key,
               \(lastBackup) AS last_backup
        FROM master.sys.certificates WHERE name NOT LIKE N'##%' ORDER BY name;
        """
        let result = try await session.metadataQuery(sql, database: "master")
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            BackupCertificate(name: row.string("name"), subject: row.string("subject"),
                              expiry: row.serverDate("expiry_date"), thumbprint: row.string("thumbprint"),
                              hasPrivateKey: row.int("has_key") == 1, privateKeyLastBackedUp: row.serverDate("last_backup"))
        }
    }

    public func hasMasterKey() async throws -> Bool {
        let result = try await session.metadataQuery(
            "SELECT COUNT(*) AS n FROM master.sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##'",
            database: "master")
        return (result.resultSets.first?.dictionaries().first?.int("n") ?? 0) > 0
    }

    /// Creates master's database master key when it is missing, then the certificate.
    public static func createScript(name: String, subject: String, expiry: Date, masterKeyPassword: String?) -> String {
        var lines: [String] = ["USE [master];"]
        if let password = masterKeyPassword, !password.isEmpty {
            lines.append("IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')")
            lines.append("    CREATE MASTER KEY ENCRYPTION BY PASSWORD = \(SQLIdentifier.literal(password));")
        }
        lines.append("CREATE CERTIFICATE \(SQLIdentifier.quote(name)) WITH SUBJECT = \(SQLIdentifier.literal(subject)), "
                     + "EXPIRY_DATE = \(ServerTime.literal(expiry));")
        return lines.joined(separator: "\n")
    }

    public func create(name: String, subject: String, expiry: Date, masterKeyPassword: String?) async throws {
        try await execute(Self.createScript(name: name, subject: subject, expiry: expiry,
                                            masterKeyPassword: masterKeyPassword))
    }

    /// The certificate and its private key, encrypted with `password`, read over the connection
    /// so no file has to be written on the server.
    public func export(name: String, password: String) async throws -> BackupCertificateBundle {
        let sql = """
        SELECT CERTENCODED(CERT_ID(\(SQLIdentifier.literal(name)))) AS certificate,
               CERTPRIVATEKEY(CERT_ID(\(SQLIdentifier.literal(name))), \(SQLIdentifier.literal(password))) AS private_key;
        """
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        let result = try await connection.query(sql)
        guard let row = result.resultSets.first?.dictionaries().first,
              case .binary(let certificate)? = row["certificate"],
              case .binary(let key)? = row["private_key"] else {
            throw SQLServerError.unsupportedOperation("The certificate \(name) or its private key could not be read.")
        }
        // Exporting counts as backing up the key, but only BACKUP CERTIFICATE records that date; the
        // window shows the export time from the bundle instead.
        return BackupCertificateBundle(name: name, certificate: Data(certificate), privateKey: Data(key),
                                       exportedFrom: await session.serverInfo.serverName, exportedAt: Date())
    }

    public static func importScript(_ bundle: BackupCertificateBundle, password: String, masterKeyPassword: String?) -> String {
        var lines: [String] = ["USE [master];"]
        if let masterKeyPassword, !masterKeyPassword.isEmpty {
            lines.append("IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')")
            lines.append("    CREATE MASTER KEY ENCRYPTION BY PASSWORD = \(SQLIdentifier.literal(masterKeyPassword));")
        }
        lines.append("CREATE CERTIFICATE \(SQLIdentifier.quote(bundle.name))")
        lines.append("    FROM BINARY = 0x\(SQLLiteral.hex([UInt8](bundle.certificate)))")
        lines.append("    WITH PRIVATE KEY (BINARY = 0x\(SQLLiteral.hex([UInt8](bundle.privateKey))),")
        lines.append("                      DECRYPTION BY PASSWORD = \(SQLIdentifier.literal(password)));")
        return lines.joined(separator: "\n")
    }

    public func importBundle(_ bundle: BackupCertificateBundle, password: String, masterKeyPassword: String?) async throws {
        try await execute(Self.importScript(bundle, password: password, masterKeyPassword: masterKeyPassword))
    }

    private func execute(_ sql: String) async throws {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        _ = try await StreamingStatement.run(sql, on: connection)
    }
}

// MARK: - Database Mail

/// Email settings for notifications: SQL Server's Database Mail, set up over the connection.
public struct DatabaseMailSettings: Codable, Hashable, Sendable {
    public var profileName: String = "SQL Backup"
    public var smtpServer: String = ""
    public var port: Int = 25
    public var useSSL: Bool = false
    public var userName: String = ""
    public var password: String = ""
    public var fromAddress: String = ""
    public var displayName: String = "SQL Backup"

    public init() {}

    public var setupScript: String {
        let profile = SQLIdentifier.literal(profileName)
        let account = SQLIdentifier.literal(profileName + " account")
        var lines: [String] = []
        lines.append("EXEC sp_configure 'show advanced options', 1; RECONFIGURE;")
        lines.append("EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE;")
        lines.append("IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = \(profile))")
        lines.append("    EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name = \(profile);")
        lines.append("IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = \(account))")
        lines.append("    EXEC msdb.dbo.sysmail_delete_account_sp @account_name = \(account);")
        var accountArguments: [String] = [
            "@account_name = \(account)", "@email_address = \(SQLIdentifier.literal(fromAddress))",
            "@display_name = \(SQLIdentifier.literal(displayName))",
            "@mailserver_name = \(SQLIdentifier.literal(smtpServer))", "@port = \(port)",
            "@enable_ssl = \(useSSL ? 1 : 0)"
        ]
        if !userName.isEmpty {
            accountArguments.append("@username = \(SQLIdentifier.literal(userName))")
            accountArguments.append("@password = \(SQLIdentifier.literal(password))")
        }
        lines.append("EXEC msdb.dbo.sysmail_add_account_sp " + accountArguments.joined(separator: ", ") + ";")
        lines.append("EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = \(profile);")
        lines.append("EXEC msdb.dbo.sysmail_add_profileaccount_sp @profile_name = \(profile), @account_name = \(account), "
                     + "@sequence_number = 1;")
        lines.append("EXEC msdb.dbo.sysmail_add_principalprofile_sp @profile_name = \(profile), @principal_name = N'public', "
                     + "@is_default = 1;")
        return lines.joined(separator: "\n")
    }
}

public struct DatabaseMailService: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    public func profiles() async throws -> [String] {
        let result = try await session.metadataQuery("SELECT name FROM msdb.dbo.sysmail_profile ORDER BY name",
                                                     database: "msdb")
        return (result.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
    }

    public func configure(_ settings: DatabaseMailSettings) async throws {
        try await execute(settings.setupScript)
    }

    public func sendTest(profile: String, recipients: String) async throws {
        var notification = BackupNotification(level: .always, recipients: recipients, mailProfile: profile)
        notification.level = .always
        try await execute(BackupMail.sendScript(notification: notification, subject: "SQL Backup test email",
                                                body: "Database Mail is set up for SQL Backup notifications."))
    }

    private func execute(_ sql: String) async throws {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        _ = try await StreamingStatement.run(sql, on: connection)
    }
}

// MARK: - Server options

public struct BackupServerSettings: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    /// `backup compression default` and `backup checksum default`, applied to every backup that
    /// does not say otherwise (including other tools' backups).
    public func setDefaults(compression: Bool, checksum: Bool, majorVersion: Int) async throws {
        var lines: [String] = ["EXEC sp_configure 'backup compression default', \(compression ? 1 : 0);"]
        if majorVersion >= 12 { lines.append("EXEC sp_configure 'backup checksum default', \(checksum ? 1 : 0);") }
        lines.append("RECONFIGURE;")
        try await execute(lines.joined(separator: "\n"))
    }

    /// Deletes backup and restore history older than a date (msdb.dbo.sp_delete_backuphistory).
    public func deleteHistory(olderThan date: Date) async throws {
        try await execute("EXEC msdb.dbo.sp_delete_backuphistory @oldest_date = \(ServerTime.literal(date));")
    }

    public func kill(sessionID: Int) async throws {
        try await execute("KILL \(sessionID);")
    }

    private func execute(_ sql: String) async throws {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        _ = try await StreamingStatement.run(sql, on: connection)
    }
}

// MARK: - Cloud credentials

/// The credential SQL Server needs to back up to a URL: a SAS token named after an Azure
/// container, or an access key named after an S3 bucket (SQL Server 2022 and later).
public enum CloudCredential {
    public static func azureScript(containerURL: String, sasToken: String) -> String {
        let url = containerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var token = sasToken.trimmingCharacters(in: .whitespaces)
        if token.hasPrefix("?") { token.removeFirst() }
        return dropScript(url) + "CREATE CREDENTIAL \(SQLIdentifier.quote(url)) WITH IDENTITY = N'SHARED ACCESS SIGNATURE', "
            + "SECRET = \(SQLIdentifier.literal(token));"
    }

    public static func s3Script(bucketURL: String, accessKey: String, secretKey: String) -> String {
        let url = bucketURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return dropScript(url) + "CREATE CREDENTIAL \(SQLIdentifier.quote(url)) WITH IDENTITY = N'S3 Access Key', "
            + "SECRET = \(SQLIdentifier.literal("\(accessKey):\(secretKey)"));"
    }

    static func dropScript(_ name: String) -> String {
        "IF EXISTS (SELECT 1 FROM sys.credentials WHERE name = \(SQLIdentifier.literal(name))) "
            + "DROP CREDENTIAL \(SQLIdentifier.quote(name));\n"
    }

    /// Credentials whose names are URLs, which backup to URL looks up by prefix.
    public static func list(session: SQLServerSession) async throws -> [String] {
        let sql = "SELECT name FROM sys.credentials WHERE name LIKE N'http%' OR name LIKE N's3://%' ORDER BY name"
        let result = try await session.metadataQuery(sql, database: "master")
        return (result.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
    }

    public static func create(_ script: String, session: SQLServerSession) async throws {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        _ = try await StreamingStatement.run(script, on: connection)
    }
}

// MARK: - Compression analyzer

/// One trial of the Compression Analyzer.
public struct CompressionTrial: Identifiable, Hashable, Sendable {
    public var id: Int { level }
    public var level: Int
    public var description: String
    public var backupSize: Int64
    public var compressedSize: Int64
    public var duration: TimeInterval

    public var ratio: Double {
        guard backupSize > 0 else { return 0 }
        return 1 - Double(compressedSize) / Double(backupSize)
    }
}

/// Backs a database up to the null device at each compression level the server distinguishes,
/// to compare size against time — what SQL Backup's Compression Analyzer shows. COPY_ONLY keeps
/// the trials out of the backup chain.
public struct CompressionAnalyzer: Sendable {
    private let session: SQLServerSession
    private let capabilities: BackupServerCapabilities

    public static let trialName = "SSMS for Mac compression analysis"

    public init(session: SQLServerSession, capabilities: BackupServerCapabilities) {
        self.session = session
        self.capabilities = capabilities
    }

    public func analyze(database: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [CompressionTrial] {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        var trials: [CompressionTrial] = []
        let levels = capabilities.distinctCompressionLevels
        for (index, level) in levels.enumerated() {
            try Task.checkCancellation()
            progress?(index, levels.count)
            var clauses: [String] = ["COPY_ONLY", "NAME = \(SQLIdentifier.literal(Self.trialName))"]
            if let compression = capabilities.compressionClause(level: level) { clauses.append(compression) }
            let started = Date()
            _ = try await StreamingStatement.run(
                "BACKUP DATABASE \(SQLIdentifier.quote(database)) TO DISK = N'NUL' WITH " + clauses.joined(separator: ", ") + ";",
                on: connection)
            let elapsed = Date().timeIntervalSince(started)
            let sizes = try await StreamingStatement.run(BackupRunner.sizeQuery(database), on: connection)
            let row = sizes.rows.first ?? [:]
            trials.append(CompressionTrial(level: level, description: capabilities.compressionDescription(level: level),
                                           backupSize: row.int64("backup_size"), compressedSize: row.int64("compressed_size"),
                                           duration: elapsed))
        }
        progress?(levels.count, levels.count)
        return trials
    }
}
