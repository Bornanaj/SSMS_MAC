import Foundation
import TDSKit

/// Runs a deployment script against a database, batch by batch.
///
/// The first error stops the run and any open transaction is rolled back, so a failed
/// deployment leaves the target as it was (for the transactional part of the script).
public struct ScriptRunner: Sendable {

    public struct Outcome: Sendable {
        public var succeeded: Bool
        public var batchesRun: Int
        public var totalBatches: Int
        public var messages: [String]
        public var error: String?
        public var failedBatch: String?
        public var duration: TimeInterval
    }

    public typealias Progress = @Sendable (Int, Int, String) -> Void

    private let session: SQLServerSession
    private let database: String

    public init(session: SQLServerSession, database: String) {
        self.session = session
        self.database = database
    }

    public func run(_ script: String, progress: Progress? = nil) async throws -> Outcome {
        let batches = BatchSplitter.split(script).filter { !$0.isEmpty }
        let started = Date()
        let connection = try await session.openConnection(database: database)
        defer { Task { try? await connection.close() } }
        let info = await session.serverInfo
        if !info.isAzureSQLDatabase, !database.isEmpty {
            _ = try await connection.query("USE \(SQLIdentifier.quote(database))")
        }

        var messages: [String] = []
        var completed = 0
        let total = batches.reduce(0) { $0 + max(1, $1.repeatCount) }
        for batch in batches {
            try Task.checkCancellation()
            for _ in 0..<max(1, batch.repeatCount) {
                progress?(completed, total, Self.summary(batch.text))
                do {
                    let result = try await connection.query(batch.text)
                    messages.append(contentsOf: result.messages.map(\.text))
                    if let failure = result.errors.first {
                        throw TDSError.server(failure)
                    }
                } catch {
                    messages.append(Self.describe(error))
                    _ = try? await connection.query("IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; SET NOEXEC OFF;")
                    return Outcome(succeeded: false, batchesRun: completed, totalBatches: total,
                                   messages: messages, error: Self.describe(error), failedBatch: batch.text,
                                   duration: Date().timeIntervalSince(started))
                }
                completed += 1
            }
        }
        progress?(total, total, "Done")
        let failed = messages.contains { $0.contains("The database update failed") }
        return Outcome(succeeded: !failed, batchesRun: completed, totalBatches: total, messages: messages,
                       error: failed ? "The script reported that the update failed." : nil, failedBatch: nil,
                       duration: Date().timeIntervalSince(started))
    }

    static func summary(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(120))
    }

    static func describe(_ error: Error) -> String {
        if case TDSError.server(let message) = error { return message.formatted }
        if let message = error as? TDSServerMessage { return message.formatted }
        return String(describing: error)
    }
}
