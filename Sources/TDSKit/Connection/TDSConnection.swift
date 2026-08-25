import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import NIOConcurrencyHelpers

/// One materialised result set.
public struct TDSResultSet: Sendable {
    public var columns: [TDSColumn]
    public var rows: [[TDSValue]]
    public init(columns: [TDSColumn], rows: [[TDSValue]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// Everything a batch produced, for callers that do not need streaming.
public struct TDSQueryResult: Sendable {
    public var resultSets: [TDSResultSet] = []
    public var messages: [TDSServerMessage] = []
    public var errors: [TDSServerMessage] = []
    public var rowsAffected: [Int64] = []
    public var returnStatus: Int32?
    public var returnValues: [TDSReturnValue] = []
    public var cancelled = false

    public var firstResultSet: TDSResultSet? { resultSets.first }
    public var totalRowsAffected: Int64 { rowsAffected.reduce(0, +) }
}

/// A live connection to a SQL Server instance speaking TDS 7.4.
public final class TDSConnection: @unchecked Sendable {

    public let channel: Channel
    public private(set) var configuration: TDSConfiguration
    public private(set) var loginAcknowledgement: TDSLoginAck?
    public private(set) var database: String
    public private(set) var negotiatedEncryption: TDSEncryptionByte = .notSupported
    public private(set) var featureAcks: [UInt8: [UInt8]] = [:]

    private let handler: TDSConnectionHandler
    private let encoder: TDSPacketWriter
    private let group: EventLoopGroup
    private let stateLock = NIOLock()
    /// One request at a time; see AsyncLock for why an actor is not enough.
    private let requestLock = AsyncLock()
    private var transactionDescriptor: UInt64 = 0
    private var _inTransaction = false
    private var _isClosed = false

    public var isClosed: Bool { stateLock.withLock { _isClosed } || !channel.isActive }
    public var inTransaction: Bool { stateLock.withLock { _inTransaction } }
    public var eventLoop: EventLoop { channel.eventLoop }

    private init(channel: Channel,
                 handler: TDSConnectionHandler,
                 encoder: TDSPacketWriter,
                 configuration: TDSConfiguration,
                 group: EventLoopGroup) {
        self.channel = channel
        self.handler = handler
        self.encoder = encoder
        self.configuration = configuration
        self.group = group
        self.database = configuration.database
    }

    // MARK: - Connecting

    public static func connect(configuration: TDSConfiguration,
                               on group: EventLoopGroup) async throws -> TDSConnection {
        var config = configuration
        var redirects = 0

        while true {
            if let instance = config.instanceName, !instance.isEmpty {
                config.port = try await SQLBrowser.resolvePort(host: config.host,
                                                               instance: instance,
                                                               group: group,
                                                               timeout: config.connectTimeout)
            }

            let connection = try await openChannel(config: config, group: group)
            do {
                if let routing = try await connection.handshake() {
                    try? await connection.close()
                    guard redirects < 3 else {
                        throw TDSError.protocolError("too many connection redirects")
                    }
                    redirects += 1
                    config.host = routing.host
                    config.port = routing.port
                    config.instanceName = nil
                    continue
                }
                return connection
            } catch {
                try? await connection.close()
                throw error
            }
        }
    }

    private static func openChannel(config: TDSConfiguration,
                                    group: EventLoopGroup) async throws -> TDSConnection {
        let encoder = TDSPacketWriter()
        encoder.packetSize = config.packetSize
        let handler = TDSConnectionHandler(allocator: ByteBufferAllocator())

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(config.connectTimeout)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                do {
                    if config.encryption == .strict {
                        let sslContext = try makeSSLContext(config: config, allowTLS13: true)
                        let ssl = try NIOSSLClientHandler(context: sslContext,
                                                          serverHostname: sniHostname(for: config))
                        try channel.pipeline.syncOperations.addHandler(ssl)
                    }
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(TDSPacketDecoder()),
                        encoder,
                        handler
                    ])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try await bootstrap.connect(host: config.host, port: config.port).get()
        let connection = TDSConnection(channel: channel, handler: handler, encoder: encoder,
                                       configuration: config, group: group)
        handler.onPacketSizeChange = { [weak encoder] size in
            encoder?.packetSize = max(TDSPacket.minPacketSize, min(size, TDSPacket.maxPacketSize))
        }
        return connection
    }

    private static func sniHostname(for config: TDSConfiguration) -> String? {
        let name = config.serverCertificateHostname ?? config.host
        // NIOSSL rejects IP literals as SNI values.
        if name.isEmpty { return nil }
        if name.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        if name.contains(":") { return nil }
        return name
    }

    private static func makeSSLContext(config: TDSConfiguration, allowTLS13: Bool) throws -> NIOSSLContext {
        var tls = TLSConfiguration.makeClientConfiguration()
        if config.trustServerCertificate {
            tls.certificateVerification = .none
        }
        tls.minimumTLSVersion = .tlsv1
        // The PRELOGIN-encapsulated handshake is only defined up to TLS 1.2; SQL Server
        // negotiates 1.3 exclusively in strict (TDS 8.0) mode.
        tls.maximumTLSVersion = allowTLS13 ? .tlsv13 : .tlsv12
        tls.renegotiationSupport = .none
        return try NIOSSLContext(configuration: tls)
    }

    // MARK: - Handshake

    /// Returns a routing target when Azure SQL asks us to reconnect elsewhere.
    private func handshake() async throws -> (host: String, port: Int)? {
        let preloginRequest = PreLoginRequest(
            encryption: encryptionByteToSend(),
            instanceName: configuration.instanceName,
            mars: false,
            federatedAuthRequired: isFederated
        )
        let response = try await sendRaw(type: .preLogin,
                                         payload: preloginRequest.serialize(allocator: channel.allocator))
        let prelogin = try PreLoginResponse(parsing: response)
        negotiatedEncryption = prelogin.encryption

        if configuration.encryption != .strict {
            switch prelogin.encryption {
            case .on, .required, .off:
                try await performTLSHandshake()
            case .notSupported:
                if configuration.encryption == .required {
                    throw TDSError.tlsFailure(
                        "The server reports that it does not support encryption. Turn off \"Encrypt connection\" to connect.")
                }
            case .clientCertificate:
                throw TDSError.unsupported("client certificate authentication")
            }
        }

        return try await performLogin(nonce: prelogin.nonce)
    }

    private var isFederated: Bool {
        if case .accessToken = configuration.authentication { return true }
        return false
    }

    private func encryptionByteToSend() -> TDSEncryptionByte {
        switch configuration.encryption {
        case .required: return .on
        case .disabled: return .notSupported
        case .strict: return .clientCertificate
        }
    }

    private func performTLSHandshake() async throws {
        let sslContext = try TDSConnection.makeSSLContext(config: configuration, allowTLS13: false)
        let wrapper = TDSTLSHandshakeWrapper()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let ssl = try NIOSSLClientHandler(context: sslContext,
                                          serverHostname: TDSConnection.sniHostname(for: configuration))
        let notifier = TDSTLSCompletionNotifier(wrapper: wrapper) { promise.succeed(()) }

        try await channel.eventLoop.submit { [channel] in
            let sync = channel.pipeline.syncOperations
            // The wrapper must already be in place before the TLS handler is added:
            // NIOSSLClientHandler writes its ClientHello as soon as it joins an
            // active channel, and that first flight has to be encapsulated too.
            try sync.addHandler(wrapper, position: .first)
            try sync.addHandler(ssl, position: .after(wrapper))
            try sync.addHandler(notifier, position: .after(ssl))
        }.get()

        let timeout = channel.eventLoop.scheduleTask(in: configuration.connectTimeout) {
            promise.fail(TDSError.timeout("the TLS handshake did not complete in time"))
        }
        do {
            try await promise.futureResult.get()
            timeout.cancel()
        } catch {
            timeout.cancel()
            throw TDSError.tlsFailure(String(describing: error))
        }
    }

    private func performLogin(nonce: [UInt8]?) async throws -> (host: String, port: Int)? {
        var login = Login7Request()
        login.hostName = configuration.clientHostName
        login.appName = configuration.applicationName
        login.serverName = configuration.instanceName.map { "\(configuration.host)\\\($0)" } ?? configuration.host
        login.database = configuration.database
        login.language = configuration.language
        login.packetSize = UInt32(configuration.packetSize)
        login.readOnlyIntent = configuration.readOnlyIntent
        login.enableUTF8 = configuration.enableUTF8

        var ntlmState: NTLMAuthenticator?

        switch configuration.authentication {
        case .sqlLogin(let username, let password):
            login.userName = username
            login.password = password
        case .accessToken(let token):
            login.fedAuthToken = token
            login.fedAuthNonce = nonce
        case .ntlm(let username, let password, let domain):
            let authenticator = NTLMAuthenticator(username: username, password: password,
                                                  domain: domain, workstation: configuration.clientHostName)
            ntlmState = authenticator
            login.useIntegratedSecurity = true
            login.sspiPayload = authenticator.negotiateMessage()
        }

        var routing: (host: String, port: Int)?
        var loginError: TDSServerMessage?
        var sspiChallenge: [UInt8]?
        var acked = false

        func drain(_ event: TDSStreamEvent) {
            switch event {
            case .loginAck(let ack):
                loginAcknowledgement = ack
                acked = true
            case .error(let message):
                if loginError == nil || message.severity > (loginError?.severity ?? 0) {
                    loginError = message
                }
            case .envChange(let change):
                apply(change)
                if case .routing(let host, let port) = change { routing = (host, port) }
            case .sspi(let payload):
                sspiChallenge = payload
            case .featureExtAck(let acks):
                featureAcks = acks
            default:
                break
            }
        }

        try await sendTokens(type: .tds7Login,
                             payload: login.serialize(allocator: channel.allocator),
                             sink: drain)

        // NTLM needs a second round trip: the server answers with a challenge.
        if let authenticator = ntlmState, let challenge = sspiChallenge {
            let response = try authenticator.authenticateMessage(challenge: challenge)
            var buffer = channel.allocator.buffer(capacity: response.count)
            buffer.writeBytes(response)
            sspiChallenge = nil
            try await sendTokens(type: .sspi, payload: buffer, sink: drain)
        }

        if let routing { return routing }

        guard acked else {
            if let loginError {
                throw TDSError.authenticationFailed(loginError)
            }
            throw TDSError.connectionClosed(reason: "the server closed the connection during login")
        }
        if let loginError, loginError.severity >= 17 {
            throw TDSError.authenticationFailed(loginError)
        }
        return nil
    }

    private func apply(_ change: TDSEnvChange) {
        switch change {
        case .database(let new, _):
            database = new
        case .packetSize(let new, _):
            encoder.packetSize = max(TDSPacket.minPacketSize, min(new, TDSPacket.maxPacketSize))
        case .beginTransaction(let descriptor):
            transactionDescriptor = TDSValueDecoder.readUInt(descriptor)
            stateLock.withLock { _inTransaction = true }
        case .commitTransaction, .rollbackTransaction:
            transactionDescriptor = 0
            stateLock.withLock { _inTransaction = false }
        default:
            break
        }
    }

    // MARK: - Low level send

    private func sendRaw(type: TDSPacketType, payload: ByteBuffer) async throws -> ByteBuffer {
        try await requestLock.withLock {
            // The promise is created and handed to the handler inside the same event
            // loop hop, so a failure here can never strand an unfulfilled promise.
            let future: EventLoopFuture<ByteBuffer> = try await channel.eventLoop.submit {
                [handler, channel] () -> EventLoopFuture<ByteBuffer> in
                guard !handler.isBusy else { throw TDSError.busy }
                let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
                handler.beginRaw(promise: promise)
                channel.writeAndFlush(TDSMessage(type: type, payload: payload), promise: nil)
                return promise.futureResult
            }.get()
            return try await future.get()
        }
    }

    private func sendTokens(type: TDSPacketType,
                            payload: ByteBuffer,
                            resetConnection: Bool = false,
                            sink: @escaping (TDSStreamEvent) -> Void) async throws {
        try await requestLock.withLock {
            let future: EventLoopFuture<Void> = try await channel.eventLoop.submit {
                [handler, channel] () -> EventLoopFuture<Void> in
                guard !handler.isBusy else { throw TDSError.busy }
                let promise = channel.eventLoop.makePromise(of: Void.self)
                handler.beginTokens(sink: sink, promise: promise)
                channel.writeAndFlush(TDSMessage(type: type, payload: payload,
                                                 resetConnection: resetConnection), promise: nil)
                return promise.futureResult
            }.get()
            try await future.get()
        }
    }

    // MARK: - Executing

    /// Stream a T-SQL batch, delivering tokens as they arrive.
    public func execute(_ sql: String,
                        resetConnection: Bool = false,
                        sink: @escaping @Sendable (TDSStreamEvent) -> Void) async throws {
        var payload = channel.allocator.buffer(capacity: sql.utf16.count * 2 + 32)
        writeAllHeaders(into: &payload)
        payload.writeUCS2String(sql)

        let localSink: (TDSStreamEvent) -> Void = { [weak self] event in
            if case .envChange(let change) = event { self?.apply(change) }
            sink(event)
        }
        try await sendTokens(type: .sqlBatch, payload: payload,
                             resetConnection: resetConnection, sink: localSink)
    }

    /// Run a batch and buffer everything it produced.
    @discardableResult
    public func query(_ sql: String) async throws -> TDSQueryResult {
        let box = ResultBox()
        try await execute(sql) { event in box.consume(event) }
        let result = box.finish()
        if let fatal = result.errors.first(where: { $0.severity >= 11 }) {
            throw TDSError.server(fatal)
        }
        return result
    }

    /// Convenience for statements whose first column of the first row is the answer.
    public func scalar(_ sql: String) async throws -> TDSValue? {
        let result = try await query(sql)
        return result.resultSets.first?.rows.first?.first
    }

    /// Ask the server to abandon the running request (SSMS's "Cancel Executing Query").
    public func cancel() {
        channel.eventLoop.execute { [channel, handler] in
            guard handler.isBusy else { return }
            handler.attentionSent = true
            let empty = channel.allocator.buffer(capacity: 0)
            channel.writeAndFlush(TDSMessage(type: .attention, payload: empty), promise: nil)
        }
    }

    public func close() async throws {
        stateLock.withLock { _isClosed = true }
        guard channel.isActive else { return }
        try? await channel.close().get()
    }

    private func writeAllHeaders(into buffer: inout ByteBuffer) {
        // ALL_HEADERS with a single transaction descriptor header.
        buffer.writeInteger(UInt32(22), endianness: .little) // TotalLength
        buffer.writeInteger(UInt32(18), endianness: .little) // HeaderLength
        buffer.writeInteger(UInt16(0x0002), endianness: .little) // Transaction descriptor
        buffer.writeInteger(transactionDescriptor, endianness: .little)
        buffer.writeInteger(UInt32(1), endianness: .little) // OutstandingRequestCount
    }
}

/// Collects streamed events into a `TDSQueryResult`.
final class ResultBox: @unchecked Sendable {
    private var result = TDSQueryResult()
    private var currentColumns: [TDSColumn] = []
    private var currentRows: [[TDSValue]] = []
    private let lock = NIOLock()

    func consume(_ event: TDSStreamEvent) {
        lock.withLock {
            switch event {
            case .columns(let columns):
                flushLocked()
                currentColumns = columns
            case .row(let values):
                currentRows.append(values)
            case .done(let info), .doneProc(let info), .doneInProc(let info):
                flushLocked()
                if info.hasRowCount { result.rowsAffected.append(info.rowCount) }
                if info.status.contains(.attention) { result.cancelled = true }
            case .info(let message):
                result.messages.append(message)
            case .error(let message):
                result.errors.append(message)
            case .returnStatus(let status):
                result.returnStatus = status
            case .returnValue(let value):
                result.returnValues.append(value)
            default:
                break
            }
        }
    }

    private func flushLocked() {
        guard !currentColumns.isEmpty else {
            currentRows.removeAll()
            return
        }
        result.resultSets.append(TDSResultSet(columns: currentColumns, rows: currentRows))
        currentColumns = []
        currentRows = []
    }

    func finish() -> TDSQueryResult {
        lock.withLock {
            flushLocked()
            return result
        }
    }
}
