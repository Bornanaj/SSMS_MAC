import Foundation
import TDSKit

// MARK: - Models

public enum ServerLogKind: Int, Sendable, CaseIterable, Identifiable {
    case sqlServer = 1
    case sqlAgent = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .sqlServer: return "SQL Server"
        case .sqlAgent: return "SQL Server Agent"
        }
    }
}

/// One line of the error log, as `sp_readerrorlog` returns it.
public struct ServerLogEntry: Sendable, Hashable, Identifiable {
    public enum Severity: Sendable, Hashable {
        case information, warning, error

        public var symbol: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .information: return "info.circle"
            }
        }
    }

    public var id: Int
    public var loggedAt: String
    /// "spid58", "Server", "Logon" — the source column SSMS shows.
    public var source: String
    public var message: String
    /// The log has no severity column, so this is inferred from the wording.
    public var severity: Severity

    public init(id: Int, loggedAt: String, source: String, message: String) {
        self.id = id
        self.loggedAt = loggedAt
        self.source = source
        self.message = message
        self.severity = ServerLogEntry.classify(message)
    }

    /// The SSMS log viewer picks its icons the same way: from the text, because the log
    /// itself carries no severity. Kept separate so the rules can be tested.
    static func classify(_ message: String) -> Severity {
        let lowered = message.lowercased()
        if lowered.hasPrefix("error") || lowered.contains("error:")
            || lowered.contains(" failed") || lowered.contains("cannot ")
            || lowered.contains("severity: 1") || lowered.contains("severity: 2") {
            return .error
        }
        if lowered.contains("warning") || lowered.contains("deprecated")
            || lowered.contains("could not") {
            return .warning
        }
        return .information
    }
}

/// One archived log file, as `sp_enumerrorlogs` reports it.
public struct ServerLogArchive: Sendable, Hashable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var writtenAt: String
    public var sizeBytes: Int64

    public init(number: Int, writtenAt: String = "", sizeBytes: Int64 = 0) {
        self.number = number
        self.writtenAt = writtenAt
        self.sizeBytes = sizeBytes
    }

    public var title: String {
        number == 0 ? "Current" : "Archive #\(number)"
    }
}

// MARK: - Service

/// The log viewer from SSMS's Management folder.
///
/// `sp_readerrorlog` needs membership of `securityadmin`, so every entry point here can
/// fail for permission reasons on a perfectly healthy instance. Callers are expected to
/// treat that as "not available" rather than as a bug.
public struct ErrorLogService: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    /// The error log is a file on the instance's host, which Azure SQL Database has no
    /// concept of.
    private func requireLog() async throws {
        let info = await session.serverInfo
        if info.isAzureSQLDatabase {
            throw SQLServerError.unsupportedOperation(
                "The error log is not available on Azure SQL Database. "
                    + "Use the Azure portal's diagnostic settings instead.")
        }
    }

    public func archives(kind: ServerLogKind = .sqlServer) async throws -> [ServerLogArchive] {
        try await requireLog()
        // sp_enumerrorlogs takes the same 1/2 log-type argument as sp_readerrorlog.
        let result = try await session.metadataQuery(
            "EXEC master.dbo.sp_enumerrorlogs \(kind.rawValue);", database: "master")
        if let failure = result.errors.first { throw failure }
        let rows = result.resultSets.first?.dictionaries() ?? []
        let archives = rows.map { row in
            ServerLogArchive(number: row.int("Archive #", default: row.int("Archive")),
                             writtenAt: row.string("Date"),
                             sizeBytes: row.int64("Log File Size (Byte)"))
        }
        // An instance that answers with nothing still has a current log to read.
        return archives.isEmpty ? [ServerLogArchive(number: 0)] : archives
    }

    /// `search` is filtered server side, which matters: a log can be tens of megabytes and
    /// dragging all of it back to filter locally is the slow way round.
    public func entries(kind: ServerLogKind = .sqlServer,
                        archive: Int = 0,
                        search: String = "",
                        limit: Int = 5000) async throws -> [ServerLogEntry] {
        try await requireLog()
        let filter = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql = "EXEC master.dbo.sp_readerrorlog \(max(0, archive)), \(kind.rawValue), "
            + (filter.isEmpty ? "NULL" : SQLIdentifier.literal(filter)) + ";"
        let result = try await session.metadataQuery(sql, database: "master")
        if let failure = result.errors.first { throw failure }
        let rows = result.resultSets.first?.dictionaries() ?? []
        return rows.prefix(max(1, limit)).enumerated().map { index, row in
            ServerLogEntry(id: index,
                           loggedAt: row.string("LogDate"),
                           source: row.string("ProcessInfo"),
                           message: row.string("Text"))
        }
    }

    /// SSMS has a Recycle button on the log viewer; the log rolls without a restart.
    public func recycle(kind: ServerLogKind = .sqlServer) async throws {
        try await requireLog()
        let procedure = kind == .sqlAgent ? "sp_cycle_agent_errorlog" : "sp_cycle_errorlog"
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        let result = try await connection.query("EXEC master.dbo.\(procedure);")
        if let failure = result.errors.first { throw failure }
    }
}
