import Foundation

// MARK: - Filter

/// Decides which objects take part in a comparison: whole object types can be switched off,
/// and rules include or exclude objects by name.
///
/// An object is compared when its type is enabled, at least one include rule for its type
/// matches (or there are none), and no exclude rule matches.
public struct SchemaFilter: Codable, Hashable, Sendable {
    public var excludedTypes: Set<SchemaObjectType>
    public var rules: [SchemaFilterRule]

    public init(excludedTypes: Set<SchemaObjectType> = [], rules: [SchemaFilterRule] = []) {
        self.excludedTypes = excludedTypes
        self.rules = rules
    }

    public func includes(_ key: SchemaObjectKey) -> Bool {
        guard !excludedTypes.contains(key.type) else { return false }
        let applicable = rules.filter { $0.isEnabled && ($0.types.isEmpty || $0.types.contains(key.type)) }
        let includeRules = applicable.filter { $0.action == .include }
        if !includeRules.isEmpty, !includeRules.contains(where: { $0.matches(key) }) { return false }
        return !applicable.contains { $0.action == .exclude && $0.matches(key) }
    }

    public var isEmpty: Bool { excludedTypes.isEmpty && rules.allSatisfy { !$0.isEnabled } }
}

public struct SchemaFilterRule: Codable, Hashable, Sendable, Identifiable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case include
        case exclude
    }

    public enum Field: String, Codable, CaseIterable, Sendable {
        case name
        case schema
        case qualifiedName

        public var title: String {
            switch self {
            case .name: return "Name"
            case .schema: return "Schema"
            case .qualifiedName: return "Schema.Name"
            }
        }
    }

    public enum Operator: String, Codable, CaseIterable, Sendable {
        case equals
        case notEquals
        case contains
        case doesNotContain
        case startsWith
        case endsWith
        case like
        case notLike
        case matchesRegex

        public var title: String {
            switch self {
            case .equals: return "equals"
            case .notEquals: return "does not equal"
            case .contains: return "contains"
            case .doesNotContain: return "does not contain"
            case .startsWith: return "starts with"
            case .endsWith: return "ends with"
            case .like: return "is like"
            case .notLike: return "is not like"
            case .matchesRegex: return "matches regex"
            }
        }
    }

    public var id: UUID
    public var isEnabled: Bool
    public var action: Action
    /// Empty means every type.
    public var types: Set<SchemaObjectType>
    public var field: Field
    public var op: Operator
    public var value: String

    public init(id: UUID = UUID(), isEnabled: Bool = true, action: Action = .exclude,
                types: Set<SchemaObjectType> = [], field: Field = .name, op: Operator = .like,
                value: String = "") {
        self.id = id
        self.isEnabled = isEnabled
        self.action = action
        self.types = types
        self.field = field
        self.op = op
        self.value = value
    }

    public func matches(_ key: SchemaObjectKey) -> Bool {
        let subject: String
        switch field {
        case .name: subject = key.name
        case .schema: subject = key.schema
        case .qualifiedName: subject = key.qualifiedName
        }
        return SchemaFilterRule.evaluate(op, subject: subject, value: value)
    }

    public static func evaluate(_ op: Operator, subject: String, value: String) -> Bool {
        let lhs = subject.lowercased()
        let rhs = value.lowercased()
        switch op {
        case .equals: return lhs == rhs
        case .notEquals: return lhs != rhs
        case .contains: return lhs.contains(rhs)
        case .doesNotContain: return !lhs.contains(rhs)
        case .startsWith: return lhs.hasPrefix(rhs)
        case .endsWith: return lhs.hasSuffix(rhs)
        case .like: return likeMatches(lhs, pattern: rhs)
        case .notLike: return !likeMatches(lhs, pattern: rhs)
        case .matchesRegex:
            return subject.range(of: value, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// T-SQL LIKE semantics: `%` any run, `_` one character, `[abc]` a set.
    public static func likeMatches(_ text: String, pattern: String) -> Bool {
        var regex = "^"
        var inSet = false
        for character in pattern {
            if inSet {
                if character == "]" { inSet = false; regex += "]" }
                else if character == "\\" { regex += "\\\\" }
                else { regex.append(character) }
                continue
            }
            switch character {
            case "%": regex += ".*"
            case "_": regex += "."
            case "[": inSet = true; regex += "["
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        if inSet { regex += "]" }
        regex += "$"
        return text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public var summary: String {
        let typeText = types.isEmpty ? "any object"
            : types.sorted().map { $0.title.lowercased() }.joined(separator: ", ")
        return "\(action == .include ? "Include" : "Exclude") \(typeText) where \(field.title) "
            + "\(op.title) '\(value)'"
    }
}

// MARK: - Mapping

/// Owner (schema) mapping, object mapping and column mapping between source and target.
public struct SchemaMappings: Codable, Hashable, Sendable {
    public var schemaMappings: [SchemaNameMapping]
    public var objectMappings: [ObjectMapping]
    public var columnMappings: [ColumnMappingSet]

    public init(schemaMappings: [SchemaNameMapping] = [], objectMappings: [ObjectMapping] = [],
                columnMappings: [ColumnMappingSet] = []) {
        self.schemaMappings = schemaMappings
        self.objectMappings = objectMappings
        self.columnMappings = columnMappings
    }

    /// The target schema a source schema maps to.
    public func targetSchema(for sourceSchema: String) -> String {
        schemaMappings.first { $0.source.caseInsensitiveCompare(sourceSchema) == .orderedSame }?.target
            ?? sourceSchema
    }

    public func sourceSchema(for targetSchema: String) -> String {
        schemaMappings.first { $0.target.caseInsensitiveCompare(targetSchema) == .orderedSame }?.source
            ?? targetSchema
    }

    public func explicitTarget(for source: SchemaObjectKey) -> SchemaObjectKey? {
        objectMappings.first { $0.source == source }?.target
    }

    public func columnMap(source: SchemaObjectKey, target: SchemaObjectKey) -> [String: String] {
        var map: [String: String] = [:]
        for set in columnMappings where set.source == source && set.target == target {
            for pair in set.pairs { map[pair.source.lowercased()] = pair.target }
        }
        return map
    }

    public var isEmpty: Bool {
        schemaMappings.isEmpty && objectMappings.isEmpty && columnMappings.isEmpty
    }
}

public struct SchemaNameMapping: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var source: String
    public var target: String

    public init(id: UUID = UUID(), source: String, target: String) {
        self.id = id
        self.source = source
        self.target = target
    }
}

public struct ObjectMapping: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var source: SchemaObjectKey
    public var target: SchemaObjectKey

    public init(id: UUID = UUID(), source: SchemaObjectKey, target: SchemaObjectKey) {
        self.id = id
        self.source = source
        self.target = target
    }
}

public struct ColumnMappingPair: Codable, Hashable, Sendable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct ColumnMappingSet: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var source: SchemaObjectKey
    public var target: SchemaObjectKey
    public var pairs: [ColumnMappingPair]

    public init(id: UUID = UUID(), source: SchemaObjectKey, target: SchemaObjectKey,
                pairs: [ColumnMappingPair]) {
        self.id = id
        self.source = source
        self.target = target
        self.pairs = pairs
    }
}
