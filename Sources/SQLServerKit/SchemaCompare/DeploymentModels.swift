import Foundation

// MARK: - Warnings

public enum DeploymentWarningSeverity: String, Codable, CaseIterable, Sendable, Comparable {
    case high
    case medium
    case low

    public static func < (lhs: DeploymentWarningSeverity, rhs: DeploymentWarningSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    public var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

public struct DeploymentWarning: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var severity: DeploymentWarningSeverity
    public var object: String
    public var message: String

    public init(id: UUID = UUID(), severity: DeploymentWarningSeverity, object: String, message: String) {
        self.id = id
        self.severity = severity
        self.object = object
        self.message = message
    }
}

// MARK: - Actions

public enum DeploymentActionKind: String, Codable, Sendable {
    case create
    case alter
    case drop
    case rebuild
    case dropAndCreate
    case rename
    case recreateDependent

    public var title: String {
        switch self {
        case .create: return "Create"
        case .alter: return "Alter"
        case .drop: return "Drop"
        case .rebuild: return "Rebuild"
        case .dropAndCreate: return "Drop and create"
        case .rename: return "Rename"
        case .recreateDependent: return "Re-create (dependency)"
        }
    }
}

/// One line of the deployment summary.
public struct DeploymentAction: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: DeploymentActionKind
    public var key: SchemaObjectKey
    public var detail: String
    /// Added because something selected needs it, not because the user ticked it.
    public var isDependency: Bool

    public init(id: UUID = UUID(), kind: DeploymentActionKind, key: SchemaObjectKey, detail: String = "",
                isDependency: Bool = false) {
        self.id = id
        self.kind = kind
        self.key = key
        self.detail = detail
        self.isDependency = isDependency
    }
}

// MARK: - Steps

/// Where a step runs relative to the others and to the transaction.
public enum DeploymentPhase: Int, Comparable, Sendable, CaseIterable {
    /// Before BEGIN TRANSACTION: full-text indexes cannot be dropped inside a transaction.
    case preTransaction = -1
    case dropForeignKeys = 0
    case drop = 1
    case rename = 2
    case main = 3
    /// Drops of objects that altered objects stop using, e.g. a function a computed column
    /// used until the column was dropped.
    case lateDrop = 4
    case addForeignKeys = 5
    case post = 6
    /// After COMMIT: full-text catalogs and indexes cannot be created inside a transaction.
    case postTransaction = 7

    public static func < (lhs: DeploymentPhase, rhs: DeploymentPhase) -> Bool { lhs.rawValue < rhs.rawValue }

    var isTransactional: Bool { self != .preTransaction && self != .postTransaction }
}

/// A group of batches that belong to one object and one phase.
public struct DeploymentStep: Sendable {
    public var phase: DeploymentPhase
    /// Object used for dependency ordering inside the phase; nil keeps insertion order.
    public var key: SchemaObjectKey?
    public var title: String
    public var batches: [String]
    var sequence: Int = 0

    public init(phase: DeploymentPhase, key: SchemaObjectKey?, title: String, batches: [String]) {
        self.phase = phase
        self.key = key
        self.title = title
        self.batches = batches
    }
}

// MARK: - Plan

public struct DeploymentPlan: Sendable {
    public var actions: [DeploymentAction]
    public var warnings: [DeploymentWarning]
    public var dependencies: [SchemaObjectKey]
    public var steps: [DeploymentStep]
    public var script: String

    public var isEmpty: Bool { steps.allSatisfy { $0.batches.isEmpty } }

    public var highestSeverity: DeploymentWarningSeverity? {
        warnings.map(\.severity).min()
    }
}
