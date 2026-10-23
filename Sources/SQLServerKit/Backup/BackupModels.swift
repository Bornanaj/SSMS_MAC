import Foundation

// MARK: - Backup type

/// What a backup contains. Copy-only is a flag on top of full and log, as in the wizard.
public enum BackupType: String, Codable, CaseIterable, Sendable, Identifiable {
    case full
    case differential
    case log

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full: return "Full"
        case .differential: return "Differential"
        case .log: return "Transaction log"
        }
    }

    /// The `<TYPE>` file name tag.
    public var tag: String {
        switch self {
        case .full: return "FULL"
        case .differential: return "DIFF"
        case .log: return "LOG"
        }
    }

    /// Native conventions: `.bak` for database backups and `.trn` for log backups.
    public var fileExtension: String { self == .log ? "trn" : "bak" }

    /// `msdb.dbo.backupset.type`.
    public var historyCode: String {
        switch self {
        case .full: return "D"
        case .differential: return "I"
        case .log: return "L"
        }
    }

    public init?(historyCode: String) {
        switch historyCode.uppercased() {
        case "D": self = .full
        case "I": self = .differential
        case "L": self = .log
        default: return nil
        }
    }
}

// MARK: - Databases

/// Which databases a backup covers. The scopes are resolved when the backup runs, so a scheduled
/// job picks up databases created after it was set up (`BACKUP DATABASES [*]`, `USER`, `SYSTEM`).
public struct DatabaseSelection: Codable, Hashable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable {
        case selected
        case all
        case user
        case system

        public var title: String {
            switch self {
            case .selected: return "Selected databases"
            case .all: return "All databases"
            case .user: return "All user databases"
            case .system: return "System databases"
            }
        }
    }

    public var scope: Scope
    public var names: [String]
    public var excluded: [String]

    public init(scope: Scope = .selected, names: [String] = [], excluded: [String] = []) {
        self.scope = scope
        self.names = names
        self.excluded = excluded
    }

    public static func databases(_ names: [String]) -> DatabaseSelection {
        DatabaseSelection(scope: .selected, names: names)
    }

    public var summary: String {
        switch scope {
        case .selected:
            return names.isEmpty ? "No databases" : names.joined(separator: ", ")
        default:
            return excluded.isEmpty ? scope.title : "\(scope.title) except \(excluded.joined(separator: ", "))"
        }
    }
}

// MARK: - Files

/// How the backup is written: one file, one file copied in parallel to mirror folders, or
/// striped over several files that are all needed to restore.
public enum BackupFileLayout: String, Codable, CaseIterable, Sendable {
    case single
    case mirrored
    case split

    public var title: String {
        switch self {
        case .single: return "Single backup file"
        case .mirrored: return "Single file mirrored to other locations"
        case .split: return "Split into multiple files"
        }
    }
}

/// Deleting older backup files of the same database and type, by age or by count.
public struct BackupRetention: Codable, Hashable, Sendable {
    public enum Rule: String, Codable, CaseIterable, Sendable {
        case none
        case olderThanDays
        case olderThanHours
        case keepLatest

        public var title: String {
            switch self {
            case .none: return "Keep all files"
            case .olderThanDays: return "Delete files older than (days)"
            case .olderThanHours: return "Delete files older than (hours)"
            case .keepLatest: return "Delete all files except the latest"
            }
        }
    }

    public var rule: Rule
    public var value: Int
    /// Delete before the backup starts instead of after it succeeds.
    public var beforeBackup: Bool

    public init(rule: Rule = .none, value: Int = 7, beforeBackup: Bool = false) {
        self.rule = rule
        self.value = value
        self.beforeBackup = beforeBackup
    }

    public var isEnabled: Bool { rule != .none && value > 0 }

    public var summary: String {
        switch rule {
        case .none: return "No files deleted"
        case .olderThanDays: return "Delete files older than \(value) day(s)"
        case .olderThanHours: return "Delete files older than \(value) hour(s)"
        case .keepLatest: return "Keep the latest \(value) file(s)"
        }
    }
}

/// Where the files go: a folder on the server (local disk or a share), or object storage.
public enum BackupDestinationKind: String, Codable, CaseIterable, Sendable {
    case disk
    case url

    public var title: String {
        switch self {
        case .disk: return "Disk (server folder or network share)"
        case .url: return "Cloud storage (Azure Blob or S3-compatible)"
        }
    }
}

// MARK: - Encryption

public enum BackupEncryptionAlgorithm: String, Codable, CaseIterable, Sendable {
    case aes128 = "AES_128"
    case aes192 = "AES_192"
    case aes256 = "AES_256"
    case tripleDES = "TRIPLE_DES_3KEY"

    public var title: String {
        switch self {
        case .aes128: return "128-bit AES"
        case .aes192: return "192-bit AES"
        case .aes256: return "256-bit AES"
        case .tripleDES: return "Triple DES"
        }
    }
}

/// Native backup encryption: the key is a certificate (or asymmetric key) in master rather than
/// a password, so restores need the certificate instead of a password.
public struct BackupEncryption: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var algorithm: BackupEncryptionAlgorithm
    public var encryptor: String
    public var usesAsymmetricKey: Bool

    public init(isEnabled: Bool = false, algorithm: BackupEncryptionAlgorithm = .aes256, encryptor: String = "",
                usesAsymmetricKey: Bool = false) {
        self.isEnabled = isEnabled
        self.algorithm = algorithm
        self.encryptor = encryptor
        self.usesAsymmetricKey = usesAsymmetricKey
    }

    var clause: String {
        let kind = usesAsymmetricKey ? "SERVER ASYMMETRIC KEY" : "SERVER CERTIFICATE"
        return "ENCRYPTION (ALGORITHM = \(algorithm.rawValue), \(kind) = \(SQLIdentifier.quote(encryptor)))"
    }
}

// MARK: - Notification

/// When to send an email about a backup or restore, through Database Mail.
public enum NotificationLevel: String, Codable, CaseIterable, Sendable {
    case never
    case errorOnly
    case errorOrWarning
    case always

    public var title: String {
        switch self {
        case .never: return "Do not send email"
        case .errorOnly: return "On error only"
        case .errorOrWarning: return "On error or warning"
        case .always: return "On any outcome"
        }
    }
}

public struct BackupNotification: Codable, Hashable, Sendable {
    public var level: NotificationLevel
    /// Addresses separated by `;`.
    public var recipients: String
    /// Database Mail profile; empty uses the default public or private profile.
    public var mailProfile: String

    public init(level: NotificationLevel = .never, recipients: String = "", mailProfile: String = "") {
        self.level = level
        self.recipients = recipients
        self.mailProfile = mailProfile
    }

    public var isEnabled: Bool {
        level != .never && !recipients.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func shouldSend(errors: Bool, warnings: Bool) -> Bool {
        switch level {
        case .never: return false
        case .errorOnly: return errors
        case .errorOrWarning: return errors || warnings
        case .always: return true
        }
    }
}

// MARK: - Options

/// Everything the Back Up and Schedule Backup Jobs wizards collect. Codable so it can be saved as
/// a template and embedded in the Agent jobs it creates, which is what makes those jobs editable.
public struct BackupOptions: Codable, Hashable, Sendable {

    public static let defaultFileNameFormat = "<TYPE>_<INSTANCE>_<DATABASE>_<DATETIME yyyymmdd_hhnnss>"

    // Type and databases
    public var type: BackupType = .full
    public var copyOnly: Bool = false
    /// Log backups only: `false` adds NO_TRUNCATE ("Remove inactive entries" unticked).
    public var truncateLog: Bool = true
    public var databases: DatabaseSelection = DatabaseSelection()

    // Files
    public var destination: BackupDestinationKind = .disk
    /// Server folder; empty means the server's default backup folder. Tags are allowed.
    public var folder: String = ""
    public var fileNameFormat: String = BackupOptions.defaultFileNameFormat
    /// For cloud backups: the container or bucket URL the files go under, for example
    /// `https://account.blob.core.windows.net/backups` or `s3://s3.us-west-2.amazonaws.com/bucket`.
    public var urlBase: String = ""
    /// S3 region, passed in BACKUP_OPTIONS; empty uses the connector's default.
    public var s3Region: String = ""
    public var layout: BackupFileLayout = .single
    public var fileCount: Int = 2
    /// Folders the backup is mirrored to (MIRROR TO), at most three.
    public var mirrorFolders: [String] = []
    /// Overwrite files with the same name. Without it a backup whose file exists fails, rather
    /// than silently appending a second backup set to that file.
    public var overwrite: Bool = false
    public var retention: BackupRetention = BackupRetention()
    public var mirrorRetention: BackupRetention = BackupRetention()

    // Processing
    /// 0 = none, 1 = fastest … 4 = smallest; mapped to the server's algorithms.
    public var compressionLevel: Int = 1
    public var encryption: BackupEncryption = BackupEncryption()
    /// Bytes; 0 leaves the server's choice.
    public var maxTransferSize: Int = 0
    public var bufferCount: Int = 0
    public var blockSize: Int = 0
    /// Network resilience: how many times a failed backup or verification is retried after a
    /// file or network error, and how long to wait between attempts.
    public var retryCount: Int = 10
    public var retryIntervalSeconds: Int = 30

    // Verification and completion
    public var checksum: Bool = true
    public var continueAfterError: Bool = false
    public var verify: Bool = false
    public var checkPreferredReplica: Bool = false
    public var secondaryReplicaCopyOnly: Bool = false
    public var notification: BackupNotification = BackupNotification()
    /// Backup set name and description; tags are allowed.
    public var backupName: String = ""
    public var backupDescription: String = ""

    public init() {}

    public var effectiveFileNameFormat: String {
        let trimmed = fileNameFormat.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultFileNameFormat : trimmed
    }

    /// Problems that make the options unusable, in wizard order.
    public func validationErrors(capabilities: BackupServerCapabilities?) -> [String] {
        var errors: [String] = []
        if databases.scope == .selected && databases.names.isEmpty {
            errors.append("Select at least one database.")
        }
        if type == .differential && copyOnly {
            errors.append("A differential backup cannot be copy-only.")
        }
        if destination == .url && urlBase.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Enter the container or bucket URL.")
        }
        if layout == .split && !(2...64).contains(fileCount) {
            errors.append("A split backup uses between 2 and 64 files.")
        }
        if layout == .mirrored {
            let folders = mirrorFolders.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if folders.isEmpty { errors.append("Enter a folder to mirror the backup to.") }
            if folders.count > 3 { errors.append("A backup can be mirrored to at most three folders.") }
            if let capabilities, !capabilities.canMirror {
                errors.append("Mirrored backups need the Enterprise or Developer edition.")
            }
        }
        let format = effectiveFileNameFormat.uppercased()
        let namesEachDatabase = format.contains("<DATABASE>") || format.contains("<AUTO>")
            || folder.uppercased().contains("<DATABASE>")
        if (databases.scope != .selected || databases.names.count > 1) && !namesEachDatabase {
            errors.append("With several databases the file name must contain <DATABASE> so each gets its own file.")
        }
        if encryption.isEnabled && encryption.encryptor.isEmpty {
            errors.append("Choose the certificate that encrypts the backup.")
        }
        if let capabilities {
            if encryption.isEnabled && !capabilities.canEncrypt {
                errors.append("\(capabilities.editionTitle) cannot create encrypted backups.")
            }
            if destination == .url && urlBase.lowercased().hasPrefix("s3://") && !capabilities.supportsS3 {
                errors.append("Backups to S3-compatible storage need SQL Server 2022 or later.")
            }
        }
        if retention.rule == .keepLatest && retention.value < 1 {
            errors.append("Keep at least one file.")
        }
        return errors
    }
}

/// A named set of options, like the wizard's "Save as template".
public struct BackupTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var options: BackupOptions

    public init(id: UUID = UUID(), name: String, options: BackupOptions) {
        self.id = id
        self.name = name
        self.options = options
    }
}

// MARK: - Results

/// Outcome of backing up one database.
public struct DatabaseBackupResult: Sendable, Hashable, Identifiable {
    public var id: String { database }
    public var database: String
    public var type: BackupType
    public var files: [String] = []
    public var mirrorFiles: [String] = []
    public var succeeded: Bool = false
    public var skipped: Bool = false
    public var verified: Bool?
    public var attempts: Int = 0
    public var errors: [String] = []
    public var warnings: [String] = []
    public var messages: [String] = []
    public var deletedFiles: [String] = []
    public var startedAt: Date = Date()
    public var duration: TimeInterval = 0
    public var backupSize: Int64 = 0
    public var compressedSize: Int64 = 0
    public var script: String = ""

    public init(database: String, type: BackupType) {
        self.database = database
        self.type = type
    }

    public var compressionRatio: Double? {
        guard backupSize > 0, compressedSize > 0 else { return nil }
        return 1 - Double(compressedSize) / Double(backupSize)
    }
}

/// Outcome of a whole backup run. The exit code is 0 for success, 1 for warnings and 2 for
/// errors (POSIX exit statuses are eight bits, so SQL Backup's 1–499 / 500+ ranges do not fit).
public struct BackupRunResult: Sendable {
    public var results: [DatabaseBackupResult]
    public var startedAt: Date
    public var duration: TimeInterval
    public var emailSent: Bool = false

    public init(results: [DatabaseBackupResult], startedAt: Date, duration: TimeInterval) {
        self.results = results
        self.startedAt = startedAt
        self.duration = duration
    }

    public var hasErrors: Bool { results.contains { !$0.succeeded && !$0.skipped } }
    public var hasWarnings: Bool { results.contains { !$0.warnings.isEmpty } }

    public var exitCode: Int32 {
        if hasErrors { return 2 }
        if hasWarnings { return 1 }
        return 0
    }

    public var summary: String {
        let done: Int = results.filter(\.succeeded).count
        let failed: Int = results.filter { !$0.succeeded && !$0.skipped }.count
        let skipped: Int = results.filter(\.skipped).count
        var parts: [String] = ["\(done) backed up"]
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        let warnings: Int = results.reduce(0) { $0 + $1.warnings.count }
        if warnings > 0 { parts.append("\(warnings) warning(s)") }
        return parts.joined(separator: ", ")
    }
}
