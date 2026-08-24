import Foundation
import NIOCore

/// How the connection should negotiate TLS.
public enum TDSEncryptionMode: String, Sendable, Codable, CaseIterable {
    /// Encrypt the whole session (what SSMS calls "Encrypt connection"). Default.
    case required
    /// Do not negotiate TLS at all. Only works when the server permits it.
    case disabled
    /// TDS 8.0 strict: TLS is established before any TDS traffic (Azure SQL, SQL Server 2022+).
    case strict
}

public enum TDSAuthentication: Sendable {
    /// SQL Server authentication.
    case sqlLogin(username: String, password: String)
    /// Windows authentication over NTLMv2.
    case ntlm(username: String, password: String, domain: String)
    /// Microsoft Entra ID: a bearer token obtained elsewhere (az CLI, MSAL…).
    case accessToken(String)

    public var displayUser: String {
        switch self {
        case .sqlLogin(let u, _): return u
        case .ntlm(let u, let p, _): _ = p; return u
        case .accessToken: return "Microsoft Entra ID"
        }
    }
}

public struct TDSConfiguration: Sendable {
    public var host: String
    public var port: Int
    /// Named instance; when set the port is resolved through the SQL Browser service.
    public var instanceName: String?
    public var database: String
    public var authentication: TDSAuthentication
    public var encryption: TDSEncryptionMode
    public var trustServerCertificate: Bool
    /// Host name used for certificate validation and SNI. Defaults to `host`.
    public var serverCertificateHostname: String?
    public var connectTimeout: TimeAmount
    public var requestTimeout: TimeAmount
    public var applicationName: String
    public var clientHostName: String
    public var packetSize: Int
    public var readOnlyIntent: Bool
    public var multiSubnetFailover: Bool
    public var enableUTF8: Bool
    public var language: String

    public init(host: String,
                port: Int = 1433,
                instanceName: String? = nil,
                database: String = "",
                authentication: TDSAuthentication,
                encryption: TDSEncryptionMode = .required,
                trustServerCertificate: Bool = true,
                serverCertificateHostname: String? = nil,
                connectTimeout: TimeAmount = .seconds(15),
                requestTimeout: TimeAmount = .seconds(0),
                applicationName: String = "SSMS for Mac",
                clientHostName: String = ProcessInfo.processInfo.hostName,
                packetSize: Int = 4096,
                readOnlyIntent: Bool = false,
                multiSubnetFailover: Bool = false,
                enableUTF8: Bool = false,
                language: String = "") {
        self.host = host
        self.port = port
        self.instanceName = instanceName
        self.database = database
        self.authentication = authentication
        self.encryption = encryption
        self.trustServerCertificate = trustServerCertificate
        self.serverCertificateHostname = serverCertificateHostname
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.applicationName = applicationName
        self.clientHostName = clientHostName
        self.packetSize = packetSize
        self.readOnlyIntent = readOnlyIntent
        self.multiSubnetFailover = multiSubnetFailover
        self.enableUTF8 = enableUTF8
        self.language = language
    }

    /// Parse the "server name" field the way SSMS does:
    /// `host`, `host,port`, `host\INSTANCE`, `tcp:host,port`, `host\INSTANCE,port`.
    public static func parseServerName(_ raw: String) -> (host: String, port: Int?, instance: String?) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["tcp:", "np:", "lpc:", "TCP:", "NP:"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.isEmpty || value == "." || value.lowercased() == "(local)" {
            return ("localhost", nil, nil)
        }

        var port: Int?
        var instance: String?

        if let commaIndex = value.lastIndex(of: ",") {
            let portPart = String(value[value.index(after: commaIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if let p = Int(portPart) {
                port = p
                value = String(value[value.startIndex..<commaIndex])
            }
        }
        if let backslash = value.firstIndex(of: "\\") {
            instance = String(value[value.index(after: backslash)...])
            value = String(value[value.startIndex..<backslash])
        }
        if value.isEmpty || value == "." || value.lowercased() == "(local)" { value = "localhost" }
        return (value, port, instance)
    }
}
