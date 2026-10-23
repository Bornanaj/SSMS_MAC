import Foundation
import TDSKit

/// One statement, and the instance it has to run on.
///
/// Most SQL Server work happens on one connection. Availability group work does not:
/// a failover runs on the replica taking over, the join runs on the new secondary, and
/// the resume runs on whichever replica is behind. A plan is that sequence written down
/// — each step naming its own target — so it can be carried out one step at a time and
/// stopped where it goes wrong.
public struct ScriptStep: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    /// Instance the step runs on, as the engine names it (`NODE2`, `NODE2\SQL2022`).
    public var instance: String
    public var database: String
    public var script: String
    /// One sentence on why this step exists, shown next to it.
    public var detail: String
    /// A check or a tidy-up the plan should survive: the next step still runs.
    public var continuesOnFailure: Bool
    /// A step that only reads, so running it can never change anything.
    public var isReadOnly: Bool

    public init(id: UUID = UUID(), title: String, instance: String, database: String = "master",
                script: String, detail: String = "", continuesOnFailure: Bool = false,
                isReadOnly: Bool = false) {
        self.id = id
        self.title = title
        self.instance = instance
        self.database = database
        self.script = script
        self.detail = detail
        self.continuesOnFailure = continuesOnFailure
        self.isReadOnly = isReadOnly
    }
}

public enum ScriptStepState: String, Sendable, Hashable {
    case pending
    case running
    case succeeded
    case failed
    case skipped

    public var isFinished: Bool { self == .succeeded || self == .failed || self == .skipped }
}

public struct ScriptStepOutcome: Sendable, Hashable {
    public var state: ScriptStepState
    public var message: String
    /// PRINT output and informational messages the batch produced.
    public var serverMessages: [String]
    public var elapsed: TimeInterval
    /// First column of the first row, when the step was a check: "PRIMARY",
    /// "SYNCHRONIZED", a count. This is what makes a verification step readable.
    public var value: String

    public init(state: ScriptStepState, message: String = "", serverMessages: [String] = [],
                elapsed: TimeInterval = 0, value: String = "") {
        self.state = state
        self.message = message
        self.serverMessages = serverMessages
        self.elapsed = elapsed
        self.value = value
    }
}

/// An ordered set of steps plus what has happened to each so far.
public struct ScriptPlan: Sendable, Hashable {
    public var title: String
    /// What the whole plan is for, shown above the steps.
    public var summary: String
    public var steps: [ScriptStep]
    public var outcomes: [UUID: ScriptStepOutcome]
    /// False lets the plan carry on past a failed step, which is almost never wanted
    /// on a cluster: a failover that did not happen must not be followed by the
    /// statements that assume it did.
    public var stopsOnFailure: Bool

    public init(title: String, summary: String = "", steps: [ScriptStep],
                stopsOnFailure: Bool = true) {
        self.title = title
        self.summary = summary
        self.steps = steps
        self.outcomes = [:]
        self.stopsOnFailure = stopsOnFailure
    }

    public func state(of step: ScriptStep) -> ScriptStepState {
        outcomes[step.id]?.state ?? .pending
    }

    public func outcome(of step: ScriptStep) -> ScriptStepOutcome? {
        outcomes[step.id]
    }

    public mutating func record(_ outcome: ScriptStepOutcome, for step: ScriptStep) {
        outcomes[step.id] = outcome
    }

    public mutating func reset() {
        outcomes.removeAll()
    }

    /// Distinct instances in the order they are first needed, which is the order the
    /// connections have to be opened in.
    public var instances: [String] {
        var seen = Set<String>()
        return steps.compactMap { step in
            let key = step.instance.lowercased()
            guard !step.instance.isEmpty, seen.insert(key).inserted else { return nil }
            return step.instance
        }
    }

    public var hasFailure: Bool {
        steps.contains { state(of: $0) == .failed && !$0.continuesOnFailure }
    }

    /// The next step to run, or nil when the plan is done or stopped by a failure.
    public func nextRunnableIndex() -> Int? {
        if stopsOnFailure && hasFailure { return nil }
        return steps.firstIndex { state(of: $0) == .pending }
    }

    public var isFinished: Bool {
        steps.allSatisfy { state(of: $0).isFinished }
    }

    public var progress: Double {
        guard !steps.isEmpty else { return 0 }
        let done = steps.filter { state(of: $0).isFinished }.count
        return Double(done) / Double(steps.count)
    }

    /// "3 of 5 done, 1 failed" — the line the dialog shows while it works.
    public var statusLine: String {
        let done = steps.filter { state(of: $0).isFinished }.count
        let failed = steps.filter { state(of: $0) == .failed }.count
        var text = "\(done) of \(steps.count) steps done"
        if failed > 0 { text += ", \(failed) failed" }
        return text + "."
    }
}

/// Runs one step on one session. Sequencing is deliberately left to the caller: the
/// point of a plan is that a person decides whether to take the next step.
public enum ScriptStepRunner {

    public static func run(_ step: ScriptStep, on session: SQLServerSession) async -> ScriptStepOutcome {
        let started = Date()
        do {
            let database = step.database.isEmpty ? "master" : step.database
            let connection = try await session.openConnection(database: database)
            defer { Task { try? await connection.close() } }

            let result = try await connection.query(step.script)
            let elapsed = Date().timeIntervalSince(started)
            let informational = result.messages.map(\.text)

            if let failure = result.errors.first {
                return ScriptStepOutcome(state: .failed,
                                         message: describe(failure),
                                         serverMessages: informational,
                                         elapsed: elapsed)
            }

            return ScriptStepOutcome(state: .succeeded,
                                     message: succeeded(result),
                                     serverMessages: informational,
                                     elapsed: elapsed,
                                     value: firstValue(result))
        } catch {
            return ScriptStepOutcome(state: .failed,
                                     message: String(describing: error),
                                     elapsed: Date().timeIntervalSince(started))
        }
    }

    static func describe(_ message: TDSServerMessage) -> String {
        "Msg \(message.number), Level \(message.severity): \(message.text)"
    }

    static func succeeded(_ result: TDSQueryResult) -> String {
        if let value = firstValueIfAny(result) { return value }
        let affected = result.totalRowsAffected
        if affected > 0 { return "\(affected) row\(affected == 1 ? "" : "s") affected." }
        return "Done."
    }

    static func firstValue(_ result: TDSQueryResult) -> String {
        firstValueIfAny(result) ?? ""
    }

    private static func firstValueIfAny(_ result: TDSQueryResult) -> String? {
        guard let row = result.resultSets.first?.rows.first, let value = row.first else {
            return nil
        }
        return value.displayString()
    }
}
