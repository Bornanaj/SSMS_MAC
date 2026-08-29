import Foundation
import TDSKit

/// Shared plumbing for the admin services.
///
/// Every statement gets a connection of its own. `DBCC`, `BACKUP`, `sp_configure` and
/// the Agent stored procedures all run long, and the Object Explorer shares a single
/// metadata connection — putting admin work on it would stall the tree.
struct AdminRunner: Sendable {

    let session: SQLServerSession

    init(session: SQLServerSession) {
        self.session = session
    }

    /// Read-only catalog reads go through the shared metadata connection: they are
    /// short, and reusing the connection avoids a login round trip per panel refresh.
    func read(_ sql: String, database: String? = nil) async throws -> [[String: TDSValue]] {
        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        return result.resultSets.first?.dictionaries() ?? []
    }

    @discardableResult
    func run(_ sql: String, database: String? = nil) async throws -> TDSQueryResult {
        let connection = try await session.openConnection(database: database)
        do {
            let result = try await connection.query(sql)
            try? await connection.close()
            if let failure = result.errors.first { throw failure }
            return result
        } catch {
            try? await connection.close()
            throw error
        }
    }

    /// Statements whose output arrives as info tokens rather than result sets —
    /// `DBCC SHRINKFILE`, `sp_detach_db`, `RECONFIGURE`.
    func runCollectingMessages(_ sql: String, database: String? = nil) async throws -> [String] {
        let collector = AdminMessageCollector()
        let connection = try await session.openConnection(database: database)
        do {
            try await connection.execute(sql) { event in
                switch event {
                case .info(let message), .error(let message):
                    collector.append(message)
                default:
                    break
                }
            }
            try? await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
        return collector.lines
    }

    /// `master` on a box product, the current database on Azure SQL Database, where
    /// there is no cross-database context to switch into.
    func serverScope(_ info: ServerInfo) -> String? {
        info.isAzureSQLDatabase ? nil : "master"
    }

    func requireBoxProduct(_ feature: String) async throws {
        let info = await session.serverInfo
        guard !info.isAzureSQLDatabase else {
            throw SQLServerError.unsupportedOperation(
                "\(feature) is not available on Azure SQL Database.")
        }
    }
}

/// The stream sink is called off the caller's isolation, so the buffer needs its own lock.
private final class AdminMessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []

    func append(_ message: TDSServerMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.lock()
        buffer.append(text)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
