import Foundation
import TDSKit

public enum SQLAuthenticationType: String, Codable, CaseIterable, Sendable, Identifiable {
    case sqlLogin
    case windows
    case entraIDPassword
    case entraIDAccessToken

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sqlLogin: return "SQL Server Authentication"
        case .windows: return "Windows Authentication (NTLM)"
        case .entraIDPassword: return "Microsoft Entra ID - Password"
        case .entraIDAccessToken: return "Microsoft Entra ID - Access Token"
        }
    }

    public var needsPassword: Bool {
        switch self {
        case .sqlLogin, .windows, .entraIDPassword: return true
        case .entraIDAccessToken: return false
        }
    }
}

/// A saved connection, equivalent to an entry in SSMS's "Connect to Server" MRU list.
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Raw text as typed: `host`, `host,1433`, `host\SQLEXPRESS`, `tcp:host,1433`.
    public var server: String
    public var authentication: SQLAuthenticationType
    public var username: String
    public var domain: String
    public var database: String
    public var savePassword: Bool
    public var encryption: TDSEncryptionMode
    public var trustServerCertificate: Bool
    public var connectTimeoutSeconds: Int
    public var executionTimeoutSeconds: Int
    public var applicationName: String
    public var applicationIntentReadOnly: Bool
    public var multiSubnetFailover: Bool
    public var packetSize: Int
    /// Tints the status bar and tab, like SSMS's "Use custom color".
    public var colorHex: String?
    public var group: String?
    public var createdAt: Date
    public var lastUsed: Date?

    public init(id: UUID = UUID(),
                name: String = "",
                server: String = "",
                authentication: SQLAuthenticationType = .sqlLogin,
                username: String = "",
                domain: String = "",
                database: String = "",
                savePassword: Bool = true,
                encryption: TDSEncryptionMode = .required,
                trustServerCertificate: Bool = true,
                connectTimeoutSeconds: Int = 15,
                executionTimeoutSeconds: Int = 0,
                applicationName: String = "SSMS for Mac",
                applicationIntentReadOnly: Bool = false,
                multiSubnetFailover: Bool = false,
                packetSize: Int = 4096,
                colorHex: String? = nil,
                group: String? = nil,
                createdAt: Date = Date(),
                lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.server = server
        self.authentication = authentication
        self.username = username
        self.domain = domain
        self.database = database
        self.savePassword = savePassword
        self.encryption = encryption
        self.trustServerCertificate = trustServerCertificate
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.executionTimeoutSeconds = executionTimeoutSeconds
        self.applicationName = applicationName
        self.applicationIntentReadOnly = applicationIntentReadOnly
        self.multiSubnetFailover = multiSubnetFailover
        self.packetSize = packetSize
        self.colorHex = colorHex
        self.group = group
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        let parsed = TDSConfiguration.parseServerName(server)
        var text = parsed.instance.map { "\(parsed.host)\\\($0)" } ?? parsed.host
        if !username.isEmpty { text += " (\(username))" }
        return text
    }

    /// Keychain account key for this profile's password.
    public var credentialKey: String {
        let parsed = TDSConfiguration.parseServerName(server)
        let instance = parsed.instance.map { "\\\($0)" } ?? ""
        return "\(parsed.host)\(instance):\(parsed.port ?? 1433):\(authentication.rawValue):\(username)"
    }

    public func makeConfiguration(password: String?,
                                  accessToken: String?,
                                  database overrideDatabase: String? = nil) throws -> TDSConfiguration {
        let parsed = TDSConfiguration.parseServerName(server)
        guard !parsed.host.isEmpty else {
            throw SQLServerError.invalidProfile("Server name is required.")
        }

        let auth: TDSAuthentication
        switch authentication {
        case .sqlLogin, .entraIDPassword:
            auth = .sqlLogin(username: username, password: password ?? "")
        case .windows:
            auth = .ntlm(username: username, password: password ?? "", domain: domain)
        case .entraIDAccessToken:
            guard let accessToken, !accessToken.isEmpty else {
                throw SQLServerError.invalidProfile("An access token is required for this authentication type.")
            }
            auth = .accessToken(accessToken)
        }

        return TDSConfiguration(
            host: parsed.host,
            port: parsed.port ?? 1433,
            instanceName: parsed.instance,
            database: overrideDatabase ?? database,
            authentication: auth,
            encryption: encryption,
            trustServerCertificate: trustServerCertificate,
            connectTimeout: .seconds(Int64(max(1, connectTimeoutSeconds))),
            requestTimeout: .seconds(Int64(max(0, executionTimeoutSeconds))),
            applicationName: applicationName,
            packetSize: packetSize,
            readOnlyIntent: applicationIntentReadOnly,
            multiSubnetFailover: multiSubnetFailover
        )
    }
}

public enum SQLServerError: Error, CustomStringConvertible {
    case invalidProfile(String)
    case notConnected
    case objectNotFound(String)
    case unsupportedOperation(String)
    case cancelled

    public var description: String {
        switch self {
        case .invalidProfile(let message): return message
        case .notConnected: return "Not connected to a server."
        case .objectNotFound(let name): return "Object not found: \(name)"
        case .unsupportedOperation(let message): return message
        case .cancelled: return "Operation cancelled."
        }
    }
}
