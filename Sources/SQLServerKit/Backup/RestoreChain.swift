import Foundation
import TDSKit

/// The backups to restore, in order: a full backup, optionally the differential based on it,
/// then contiguous log backups.
public struct RestoreChain: Sendable, Hashable {
    public var full: BackupSetInfo
    public var differential: BackupSetInfo?
    public var logs: [BackupSetInfo]
    /// Stop the last log at this time (point-in-time restore).
    public var stopAt: Date?
    public var notes: [String] = []

    public init(full: BackupSetInfo, differential: BackupSetInfo?, logs: [BackupSetInfo], stopAt: Date? = nil) {
        self.full = full
        self.differential = differential
        self.logs = logs
        self.stopAt = stopAt
    }

    public var steps: [BackupSetInfo] {
        var steps: [BackupSetInfo] = [full]
        if let differential { steps.append(differential) }
        steps.append(contentsOf: logs)
        return steps
    }

    /// The earliest time a point-in-time restore can stop at: the end of the base backup.
    public var earliestTime: Date? { (differential ?? full).finished }

    /// The latest time the chain reaches.
    public var latestTime: Date? {
        guard let last = logs.last else { return (differential ?? full).finished }
        return last.lastValidRestoreTime ?? last.finished
    }

    /// The time the restored database will reflect.
    public var restoredTime: Date? { stopAt ?? latestTime }
}

public enum RestoreChainError: Error, CustomStringConvertible, Equatable {
    case noFullBackup
    case noBaseForDifferential
    case brokenLogChain(after: Date?)
    case pointInTimeTooEarly(Date?)
    case pointInTimeNotCovered(latest: Date?)
    case unsupported(String)

    public var description: String {
        switch self {
        case .noFullBackup:
            return "There is no full backup to start the restore from."
        case .noBaseForDifferential:
            return "The full backup this differential is based on was not found."
        case .brokenLogChain(let after):
            let when = after.map { " after \(ServerTime.display($0))" } ?? ""
            return "The log backup chain is broken\(when): a log backup is missing."
        case .pointInTimeTooEarly(let earliest):
            let when = earliest.map { ServerTime.display($0) } ?? "the first backup"
            return "That point in time is earlier than \(when), the earliest the backups can restore to."
        case .pointInTimeNotCovered(let latest):
            let when = latest.map { ServerTime.display($0) } ?? "the last backup"
            return "The log backups only reach \(when)."
        case .unsupported(let message):
            return message
        }
    }
}

/// Picks the backups for a restore, by the LSN rules SQL Server applies when it restores them.
public enum RestoreChainBuilder {

    /// The chain that ends with `target`: the backup the user picked in the list.
    public static func chain(ending target: BackupSetInfo,
                             in sets: [BackupSetInfo]) -> Result<RestoreChain, RestoreChainError> {
        if target.isFull { return .success(RestoreChain(full: target, differential: nil, logs: [])) }
        if target.isDifferential {
            guard let full = base(of: target, in: sets) else { return .failure(.noBaseForDifferential) }
            return .success(RestoreChain(full: full, differential: target, logs: []))
        }
        guard target.isLog else { return .failure(.unsupported("File and partial backups are restored from Transact-SQL.")) }
        var lastError: RestoreChainError = .noFullBackup
        for candidate in baseCandidates(before: target.lastLSN, notAfter: target.finished, in: sets) {
            switch logs(from: candidate.base, through: target, in: sets) {
            case .success(let logs):
                return .success(RestoreChain(full: candidate.full, differential: candidate.differential, logs: logs))
            case .failure(let error):
                lastError = error
            }
        }
        return .failure(lastError)
    }

    /// The chain that restores to `time`, or to the latest point the backups reach when nil.
    public static func chain(pointInTime time: Date?,
                             in sets: [BackupSetInfo]) -> Result<RestoreChain, RestoreChainError> {
        let fulls: [BackupSetInfo] = sets.filter { $0.isFull && $0.deviceType != 7 }
            .sorted { ($0.finished ?? .distantPast) > ($1.finished ?? .distantPast) }
        guard !fulls.isEmpty else { return .failure(.noFullBackup) }
        let usable: [BackupSetInfo] = time.map { cutoff in
            fulls.filter { ($0.finished ?? .distantFuture) <= cutoff }
        } ?? fulls
        guard !usable.isEmpty else {
            return .failure(.pointInTimeTooEarly(fulls.last?.finished))
        }
        var lastError: RestoreChainError = .noFullBackup
        for full in usable {
            var bases: [(BackupSetInfo, BackupSetInfo?)] = []
            if let differential = newestDifferential(for: full, notAfter: time, in: sets) {
                bases.append((differential, differential))
            }
            bases.append((full, nil))
            for (base, differential) in bases {
                switch logsCovering(time, from: base, in: sets) {
                case .success(let logs):
                    var chain = RestoreChain(full: full, differential: differential, logs: logs)
                    if let time, let latest = chain.latestTime, time < latest, !logs.isEmpty {
                        chain.stopAt = time
                    }
                    if let time, logs.isEmpty, let finished = base.finished, time > finished.addingTimeInterval(1) {
                        chain.notes.append("No log backups follow; the database is restored to "
                                           + "\(ServerTime.display(finished)).")
                    }
                    return .success(chain)
                case .failure(let error):
                    lastError = error
                }
            }
        }
        return .failure(lastError)
    }

    // MARK: - Pieces

    /// The full backup a differential is based on.
    static func base(of differential: BackupSetInfo, in sets: [BackupSetInfo]) -> BackupSetInfo? {
        sets.first { $0.isFull && !$0.isCopyOnly && $0.checkpointLSN == differential.databaseBackupLSN }
            ?? sets.first { $0.isFull && $0.checkpointLSN == differential.databaseBackupLSN }
    }

    static func newestDifferential(for full: BackupSetInfo, notAfter time: Date?,
                                   in sets: [BackupSetInfo]) -> BackupSetInfo? {
        guard !full.isCopyOnly else { return nil }
        return sets.filter { set in
            set.isDifferential && set.databaseBackupLSN == full.checkpointLSN
                && (time.map { (set.finished ?? .distantFuture) <= $0 } ?? true)
        }.max { ($0.finished ?? .distantPast) < ($1.finished ?? .distantPast) }
    }

    struct BaseCandidate {
        var full: BackupSetInfo
        var differential: BackupSetInfo?
        var base: BackupSetInfo { differential ?? full }
    }

    /// Bases a log chain could start from, newest first, each differential before its full.
    static func baseCandidates(before lsn: LSN, notAfter time: Date?, in sets: [BackupSetInfo]) -> [BaseCandidate] {
        let fulls: [BackupSetInfo] = sets.filter { $0.isFull && $0.deviceType != 7 && $0.lastLSN <= lsn }
            .sorted { $0.lastLSN > $1.lastLSN }
        var candidates: [BaseCandidate] = []
        for full in fulls {
            let differentials: [BackupSetInfo] = full.isCopyOnly ? [] : sets.filter {
                $0.isDifferential && $0.databaseBackupLSN == full.checkpointLSN && $0.lastLSN <= lsn
            }.sorted { $0.lastLSN > $1.lastLSN }
            for differential in differentials {
                candidates.append(BaseCandidate(full: full, differential: differential))
            }
            candidates.append(BaseCandidate(full: full, differential: nil))
        }
        return candidates
    }

    /// The log after `base` that continues from it.
    static func firstLog(after base: BackupSetInfo, in logs: [BackupSetInfo]) -> BackupSetInfo? {
        logs.filter { $0.firstLSN <= base.lastLSN && $0.lastLSN > base.lastLSN }
            .min { $0.lastLSN < $1.lastLSN }
    }

    static func regularLogs(_ sets: [BackupSetInfo]) -> [BackupSetInfo] {
        sets.filter { $0.isLog && !$0.isCopyOnly && $0.deviceType != 7 }
    }

    /// Contiguous logs from `base` up to and including `target`.
    static func logs(from base: BackupSetInfo, through target: BackupSetInfo,
                     in sets: [BackupSetInfo]) -> Result<[BackupSetInfo], RestoreChainError> {
        var pool = regularLogs(sets)
        if target.isCopyOnly { pool.append(target) }
        guard var current = firstLog(after: base, in: pool) else {
            return .failure(.brokenLogChain(after: base.finished))
        }
        var chain: [BackupSetInfo] = [current]
        while current.id != target.id {
            if current.lastLSN >= target.lastLSN { return .failure(.brokenLogChain(after: current.finished)) }
            guard let next = pool.filter({ $0.firstLSN == current.lastLSN && $0.id != current.id })
                .min(by: { $0.lastLSN < $1.lastLSN }) else {
                return .failure(.brokenLogChain(after: current.finished))
            }
            current = next
            chain.append(current)
        }
        return .success(chain)
    }

    /// Contiguous logs from `base` until one reaches `time` (or until the chain ends).
    static func logsCovering(_ time: Date?, from base: BackupSetInfo,
                             in sets: [BackupSetInfo]) -> Result<[BackupSetInfo], RestoreChainError> {
        if let time, let finished = base.finished, time <= finished { return .success([]) }
        let pool = regularLogs(sets)
        guard var current = firstLog(after: base, in: pool) else {
            if time == nil { return .success([]) }
            let later = pool.contains { ($0.finished ?? .distantPast) > (base.finished ?? .distantPast) }
            return later ? .failure(.brokenLogChain(after: base.finished)) : .success([])
        }
        var chain: [BackupSetInfo] = [current]
        while true {
            let end: Date = current.lastValidRestoreTime ?? current.finished ?? .distantPast
            if let time, end >= time { return .success(chain) }
            guard let next = pool.filter({ $0.firstLSN == current.lastLSN && $0.id != current.id })
                .min(by: { $0.lastLSN < $1.lastLSN }) else {
                if time == nil { return .success(chain) }
                let later = pool.contains { ($0.finished ?? .distantPast) > end }
                return later ? .failure(.brokenLogChain(after: current.finished))
                    : .failure(.pointInTimeNotCovered(latest: end))
            }
            current = next
            chain.append(current)
        }
    }
}

// MARK: - Reading backup files

/// Reads the headers of backup files on the server, for restoring from files rather than from
/// history: groups stripes and mirrors into media sets with RESTORE LABELONLY, then lists their
/// backup sets with RESTORE HEADERONLY.
public struct BackupMediaReader: Sendable {
    let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    public struct Label: Sendable, Hashable {
        public var path: String
        public var mediaSetID: String
        public var familyCount: Int
        public var familySequence: Int
        public var mirrorCount: Int
    }

    public struct ReadResult: Sendable {
        public var sets: [BackupSetInfo]
        public var problems: [String]
    }

    static func device(_ path: String) -> String {
        let lower = path.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("s3://") ? "URL" : "DISK"
    }

    static func fromClause(_ paths: [String]) -> String {
        paths.map { "\(device($0)) = \(SQLIdentifier.literal($0))" }.joined(separator: ", ")
    }

    public func label(path: String) async throws -> Label {
        let result = try await query("RESTORE LABELONLY FROM \(Self.fromClause([path]));")
        guard let row = result.resultSets.first?.dictionaries().first else {
            throw SQLServerError.unsupportedOperation("\(path) is not a SQL Server backup file.")
        }
        return Label(path: path, mediaSetID: row.string("MediaSetId").uppercased(),
                     familyCount: row.int("FamilyCount", default: 1),
                     familySequence: row.int("FamilySequenceNumber", default: 1),
                     mirrorCount: row.int("MirrorCount", default: 1))
    }

    /// Every backup set in the given files. Stripes of one media set are read together; a set
    /// with missing stripes is reported instead.
    public func read(paths: [String]) async -> ReadResult {
        var problems: [String] = []
        var labels: [Label] = []
        for path in paths {
            if path.lowercased().hasSuffix(".sqb") {
                problems.append("\(path) is a Redgate SQL Backup file. Convert it to a native backup with "
                                + "SQBConverter first.")
                continue
            }
            do {
                labels.append(try await label(path: path))
            } catch {
                problems.append("\(path): \(ScriptRunner.describe(error))")
            }
        }
        var sets: [BackupSetInfo] = []
        let groups = Dictionary(grouping: labels, by: \.mediaSetID)
        for (media, members) in groups.sorted(by: { $0.key < $1.key }) {
            let count = members.first?.familyCount ?? 1
            // One file per stripe is enough; a mirror's copy of the same stripe is interchangeable.
            var stripes: [Int: String] = [:]
            for member in members where stripes[member.familySequence] == nil {
                stripes[member.familySequence] = member.path
            }
            guard stripes.count == count else {
                let missing = (1...max(1, count)).filter { stripes[$0] == nil }.map(String.init).joined(separator: ", ")
                problems.append("Backup stripe(s) \(missing) of \(count) are missing for "
                                + "\(members.map(\.path).joined(separator: ", ")).")
                continue
            }
            let ordered: [String] = (1...count).compactMap { stripes[$0] }
            do {
                sets.append(contentsOf: try await headers(files: ordered, mediaKey: media))
            } catch {
                problems.append("\(ordered.joined(separator: ", ")): \(ScriptRunner.describe(error))")
            }
        }
        return ReadResult(sets: sets, problems: problems)
    }

    func headers(files: [String], mediaKey: String) async throws -> [BackupSetInfo] {
        let result = try await query("RESTORE HEADERONLY FROM \(Self.fromClause(files));")
        let rows = result.resultSets.first?.dictionaries() ?? []
        return rows.map { row in
            let position = row.int("Position", default: 1)
            var info = BackupSetInfo(id: Self.syntheticID(mediaKey, position), database: row.string("DatabaseName"),
                                     typeCode: Self.typeCode(row.int("BackupType")), position: position,
                                     firstLSN: LSN(row.string("FirstLSN")), lastLSN: LSN(row.string("LastLSN")),
                                     checkpointLSN: LSN(row.string("CheckpointLSN")),
                                     databaseBackupLSN: LSN(row.string("DatabaseBackupLSN")),
                                     differentialBaseLSN: LSN(row.string("DifferentialBaseLSN")),
                                     started: row.serverDate("BackupStartDate"),
                                     finished: row.serverDate("BackupFinishDate"),
                                     files: [files], isCopyOnly: row.int("IsCopyOnly") == 1)
            info.serverName = row.string("ServerName")
            info.lastValidRestoreTime = row.serverDate("LastValidRestoreTime")
            info.firstRecoveryForkID = row.string("FirstRecoveryForkID").uppercased()
            info.lastRecoveryForkID = row.string("RecoveryForkID").uppercased()
            info.backupSize = row.int64("BackupSize")
            info.compressedSize = row.int64("CompressedBackupSize", default: info.backupSize)
            info.keyAlgorithm = row.string("KeyAlgorithm")
            if case .binary(let bytes)? = row["EncryptorThumbprint"] { info.encryptorThumbprint = SQLLiteral.hex(bytes) }
            info.hasChecksums = row.int("HasBackupChecksums") == 1
            info.isDamaged = row.int("IsDamaged") == 1
            info.recoveryModel = row.string("RecoveryModel")
            info.deviceType = Self.device(files.first ?? "") == "URL" ? 9 : 2
            info.name = row.string("BackupName")
            info.setDescription = row.string("BackupDescription")
            return info
        }
    }

    /// Files have no backup_set_id; a stable number from the media set and position stands in.
    static func syntheticID(_ media: String, _ position: Int) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in media.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return -Int((hash % 1_000_000_000) * 100 + UInt64(position % 100))
    }

    /// HEADERONLY's numeric BackupType as msdb's letter.
    static func typeCode(_ type: Int) -> String {
        switch type {
        case 1: return "D"
        case 2: return "L"
        case 4: return "F"
        case 5: return "I"
        case 6: return "G"
        case 7: return "P"
        case 8: return "Q"
        default: return "?"
        }
    }

    private func query(_ sql: String) async throws -> TDSQueryResult {
        let connection = try await session.openConnection(database: "master")
        do {
            let result = try await connection.query(sql)
            try? await connection.close()
            return result
        } catch {
            try? await connection.close()
            throw error
        }
    }
}
