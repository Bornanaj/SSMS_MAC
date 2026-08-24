import Foundation
import NIOCore
import NIOPosix
import TDSKit

/// Shared event loop group for every connection the app makes.
public enum SQLServerRuntime {
    public static let group: EventLoopGroup = MultiThreadedEventLoopGroup(
        numberOfThreads: max(2, min(4, System.coreCount))
    )
}

/// A connected server. Owns a metadata connection used by the Object Explorer and
/// hands out dedicated connections for query windows, mirroring how SSMS gives
/// every query tab its own SPID.
public actor SQLServerSession: Identifiable {

    public nonisolated let id: UUID
    public nonisolated let profile: ConnectionProfile
    private let password: String?
    private let accessToken: String?

    public private(set) var serverInfo: ServerInfo
    private var metadataConnection: TDSConnection
    /// Azure SQL Database forbids USE, so metadata needs one connection per database.
    private var perDatabaseConnections: [String: TDSConnection] = [:]
    private var closed = false

    private init(id: UUID,
                 profile: ConnectionProfile,
                 password: String?,
                 accessToken: String?,
                 connection: TDSConnection,
                 serverInfo: ServerInfo) {
        self.id = id
        self.profile = profile
        self.password = password
        self.accessToken = accessToken
        self.metadataConnection = connection
        self.serverInfo = serverInfo
    }

    public static func connect(profile: ConnectionProfile,
                               password: String?,
                               accessToken: String? = nil,
                               group: EventLoopGroup = SQLServerRuntime.group) async throws -> SQLServerSession {
        let configuration = try profile.makeConfiguration(password: password, accessToken: accessToken)
        let connection = try await TDSConnection.connect(configuration: configuration, on: group)
        var info = ServerInfo()
        do {
            let result = try await connection.query(ServerInfo.query)
            if let row = result.resultSets.first?.dictionaries().first {
                info = ServerInfo(row: row)
            }
        } catch {
            info.serverName = TDSConfiguration.parseServerName(profile.server).host
        }
        if info.currentDatabase.isEmpty { info.currentDatabase = connection.database }
        return SQLServerSession(id: profile.id, profile: profile, password: password,
                                accessToken: accessToken, connection: connection, serverInfo: info)
    }

    /// Open a fresh connection, e.g. for a new query window.
    public func openConnection(database: String? = nil) async throws -> TDSConnection {
        let configuration = try profile.makeConfiguration(
            password: password,
            accessToken: accessToken,
            database: database ?? serverInfo.currentDatabase
        )
        return try await TDSConnection.connect(configuration: configuration, on: SQLServerRuntime.group)
    }

    /// Run a catalog query in the context of `database`.
    @discardableResult
    public func metadataQuery(_ sql: String, database: String? = nil) async throws -> TDSQueryResult {
        let connection = try await metadataConnection(for: database)
        if let database, !database.isEmpty, !serverInfo.isAzureSQLDatabase,
           connection.database.caseInsensitiveCompare(database) != .orderedSame {
            _ = try await connection.query("USE \(SQLIdentifier.quote(database));")
        }
        return try await connection.query(sql)
    }

    private func metadataConnection(for database: String?) async throws -> TDSConnection {
        guard !closed else { throw SQLServerError.notConnected }

        if serverInfo.isAzureSQLDatabase, let database, !database.isEmpty,
           database.caseInsensitiveCompare(metadataConnection.database) != .orderedSame {
            let key = database.lowercased()
            if let existing = perDatabaseConnections[key], !existing.isClosed { return existing }
            let connection = try await openConnection(database: database)
            perDatabaseConnections[key] = connection
            return connection
        }

        if metadataConnection.isClosed {
            metadataConnection = try await openConnection(database: serverInfo.currentDatabase)
        }
        return metadataConnection
    }

    public func refreshServerInfo() async throws {
        let result = try await metadataQuery(ServerInfo.query)
        if let row = result.resultSets.first?.dictionaries().first {
            serverInfo = ServerInfo(row: row)
        }
    }

    public func close() async {
        closed = true
        try? await metadataConnection.close()
        for connection in perDatabaseConnections.values {
            try? await connection.close()
        }
        perDatabaseConnections.removeAll()
    }

    public var isClosed: Bool { closed || metadataConnection.isClosed }
}

/// Quoting helpers shared by the scripter, the metadata layer and the UI.
public enum SQLIdentifier {
    /// Wrap in brackets, doubling any closing bracket, exactly like QUOTENAME().
    public static func quote(_ name: String) -> String {
        "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
    }

    public static func quote(schema: String, name: String) -> String {
        quote(schema) + "." + quote(name)
    }

    public static func quote(database: String, schema: String, name: String) -> String {
        quote(database) + "." + quote(schema) + "." + quote(name)
    }

    /// Escape a value for use inside a single quoted T-SQL string literal.
    public static func literal(_ value: String) -> String {
        "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// True when the identifier can appear unquoted in a script.
    public static func isRegular(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@#$"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !TSQLKeywords.reserved.contains(name.uppercased())
    }
}
