import Foundation

/// A message emitted by the server through an INFO or ERROR token.
public struct TDSServerMessage: Error, Sendable, Hashable, Codable {
    public var number: Int32
    public var state: UInt8
    public var severity: UInt8
    public var text: String
    public var serverName: String
    public var procedureName: String
    public var lineNumber: Int32

    public init(number: Int32, state: UInt8, severity: UInt8, text: String,
                serverName: String = "", procedureName: String = "", lineNumber: Int32 = 0) {
        self.number = number
        self.state = state
        self.severity = severity
        self.text = text
        self.serverName = serverName
        self.procedureName = procedureName
        self.lineNumber = lineNumber
    }

    /// Severity >= 11 means the statement failed.
    public var isError: Bool { severity >= 11 }

    /// SSMS renders errors as: Msg 208, Level 16, State 1, Line 1
    public var formatted: String {
        var head = "Msg \(number), Level \(severity), State \(state)"
        if !procedureName.isEmpty { head += ", Procedure \(procedureName)" }
        head += ", Line \(lineNumber)"
        return head + "\n" + text
    }
}

extension TDSServerMessage: CustomStringConvertible {
    public var description: String { formatted }
}

/// Thrown by parsers when the buffer holds only part of a structure.
/// The stream parser catches this, rewinds, and waits for the next packet.
public struct TDSNeedMoreData: Error { public init() {} }

public enum TDSError: Error, CustomStringConvertible {
    case connectionClosed(reason: String)
    case protocolError(String)
    case unsupported(String)
    case authenticationFailed(TDSServerMessage)
    case server(TDSServerMessage)
    case timeout(String)
    case tlsFailure(String)
    case invalidConfiguration(String)
    case instanceNotFound(String)
    case cancelled
    case notConnected
    case busy

    public var description: String {
        switch self {
        case .connectionClosed(let r): return "Connection closed: \(r)"
        case .protocolError(let m): return "TDS protocol error: \(m)"
        case .unsupported(let m): return "Unsupported: \(m)"
        case .authenticationFailed(let m): return "Login failed: \(m.text)"
        case .server(let m): return m.formatted
        case .timeout(let m): return "Timeout: \(m)"
        case .tlsFailure(let m): return "TLS failure: \(m)"
        case .invalidConfiguration(let m): return "Invalid configuration: \(m)"
        case .instanceNotFound(let m): return "SQL Server instance not found: \(m)"
        case .cancelled: return "Query was cancelled by the user."
        case .notConnected: return "The connection is not open."
        case .busy: return "The connection is busy with another request."
        }
    }
}
