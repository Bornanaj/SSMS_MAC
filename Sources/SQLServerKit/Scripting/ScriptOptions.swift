import Foundation

// MARK: - Script action

/// The entries SSMS puts under "Script <object> as".
public enum ScriptAction: String, CaseIterable, Sendable {
    case create
    case alter
    case drop
    case dropAndCreate
    case select
    case insert
    case update
    case delete
    case execute

    public var menuTitle: String {
        switch self {
        case .create: return "CREATE To"
        case .alter: return "ALTER To"
        case .drop: return "DROP To"
        case .dropAndCreate: return "DROP And CREATE To"
        case .select: return "SELECT To"
        case .insert: return "INSERT To"
        case .update: return "UPDATE To"
        case .delete: return "DELETE To"
        case .execute: return "Execute Stored Procedure"
        }
    }

    /// SELECT/INSERT/UPDATE/DELETE produce a statement template rather than DDL,
    /// which changes both the header wording and whether options like `scriptIndexes` apply.
    public var isDataManipulation: Bool {
        switch self {
        case .select, .insert, .update, .delete: return true
        default: return false
        }
    }
}

// MARK: - Options

/// Mirrors the subset of Tools > Options > SQL Server Object Explorer > Scripting
/// that the scripting engine actually honours.
public struct ScriptOptions: Sendable, Hashable, Codable {

    /// Emits the `/****** Object: ... Script Date: ... ******/` banner.
    public var includeDescriptiveHeader: Bool

    /// Wraps CREATE in the existence guard SSMS calls "Check for object existence".
    public var includeIfNotExists: Bool

    /// Prefixes a CREATE script with the matching DROP statement.
    public var includeDropIfExists: Bool

    public var scriptIndexes: Bool
    public var scriptTriggers: Bool
    public var scriptForeignKeys: Bool
    public var scriptCheckConstraints: Bool
    public var scriptDefaults: Bool
    public var scriptPrimaryKey: Bool
    public var scriptExtendedProperties: Bool

    /// Emit `COLLATE` on columns whose collation differs from the database default.
    public var scriptCollation: Bool

    /// Emit `IDENTITY(seed, increment)`.
    public var scriptIdentity: Bool

    /// Two-part names. When false the script relies on the caller's default schema.
    public var schemaQualify: Bool

    /// Row cap used by the SELECT template; 0 removes the TOP clause entirely.
    public var selectTopRows: Int

    /// Leading `SET ANSI_NULLS ON` / `SET QUOTED_IDENTIFIER ON` batches.
    public var includeSetOptionsHeader: Bool

    public init() {
        includeDescriptiveHeader = true
        includeIfNotExists = false
        includeDropIfExists = false
        scriptIndexes = true
        scriptTriggers = true
        scriptForeignKeys = true
        scriptCheckConstraints = true
        scriptDefaults = true
        scriptPrimaryKey = true
        scriptExtendedProperties = true
        scriptCollation = true
        scriptIdentity = true
        schemaQualify = true
        selectTopRows = 1000
        includeSetOptionsHeader = true
    }
}
