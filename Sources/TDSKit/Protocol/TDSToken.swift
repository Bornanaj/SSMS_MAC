import Foundation
import NIOCore

/// One column of a result set, as described by COLMETADATA.
public struct TDSColumn: Sendable, Hashable {
    public var index: Int
    public var name: String
    public var typeInfo: TDSTypeInfo
    public var userType: UInt32
    public var nullable: Bool
    public var caseSensitive: Bool
    /// 0 = read only, 1 = read/write, 2 = unknown
    public var updatable: Int
    public var identity: Bool
    public var computed: Bool
    public var sparse: Bool
    public var encrypted: Bool
    public var hidden: Bool
    public var tableName: String?

    public var sqlTypeName: String { typeInfo.sqlTypeName }
    public var isReadOnly: Bool { updatable == 0 || identity || computed }

    public init(index: Int, name: String, typeInfo: TDSTypeInfo, userType: UInt32 = 0,
                nullable: Bool = true, caseSensitive: Bool = false, updatable: Int = 2,
                identity: Bool = false, computed: Bool = false, sparse: Bool = false,
                encrypted: Bool = false, hidden: Bool = false, tableName: String? = nil) {
        self.index = index
        self.name = name
        self.typeInfo = typeInfo
        self.userType = userType
        self.nullable = nullable
        self.caseSensitive = caseSensitive
        self.updatable = updatable
        self.identity = identity
        self.computed = computed
        self.sparse = sparse
        self.encrypted = encrypted
        self.hidden = hidden
        self.tableName = tableName
    }
}

public struct TDSDoneStatus: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let final = TDSDoneStatus([])
    public static let more = TDSDoneStatus(rawValue: 0x0001)
    public static let error = TDSDoneStatus(rawValue: 0x0002)
    public static let inTransaction = TDSDoneStatus(rawValue: 0x0004)
    public static let count = TDSDoneStatus(rawValue: 0x0010)
    public static let attention = TDSDoneStatus(rawValue: 0x0020)
    public static let serverError = TDSDoneStatus(rawValue: 0x0100)
}

public struct TDSDoneInfo: Sendable {
    public var status: TDSDoneStatus
    public var currentCommand: UInt16
    public var rowCount: Int64
    /// True when the row count is meaningful (the DONE_COUNT bit is set).
    public var hasRowCount: Bool { status.contains(.count) }
    public var isFinal: Bool { !status.contains(.more) }
}

public struct TDSLoginAck: Sendable {
    public var interfaceType: UInt8
    public var tdsVersion: UInt32
    public var programName: String
    public var majorVersion: UInt8
    public var minorVersion: UInt8
    public var buildNumber: UInt16

    public var versionString: String { "\(majorVersion).\(minorVersion).\(buildNumber)" }
}

public enum TDSEnvChange: Sendable {
    case database(new: String, old: String)
    case language(new: String, old: String)
    case characterSet(new: String, old: String)
    case packetSize(new: Int, old: Int)
    case sqlCollation(new: [UInt8], old: [UInt8])
    case beginTransaction([UInt8])
    case commitTransaction([UInt8])
    case rollbackTransaction([UInt8])
    case resetConnectionAck
    case routing(host: String, port: Int)
    case other(type: UInt8)
}

public struct TDSReturnValue: Sendable {
    public var ordinal: Int
    public var name: String
    public var status: UInt8
    public var column: TDSColumn
    public var value: TDSValue
}

/// Everything the token stream can produce.
public enum TDSToken: Sendable {
    case columnMetadata([TDSColumn])
    case row([TDSValue])
    case done(TDSDoneInfo)
    case doneProc(TDSDoneInfo)
    case doneInProc(TDSDoneInfo)
    case info(TDSServerMessage)
    case error(TDSServerMessage)
    case envChange(TDSEnvChange)
    case loginAck(TDSLoginAck)
    case returnStatus(Int32)
    case returnValue(TDSReturnValue)
    case order([Int])
    case sspi([UInt8])
    case fedAuthInfo(stsURL: String, spn: String)
    case featureExtAck([UInt8: [UInt8]])
    case sessionState
    case tableName([String])
}
