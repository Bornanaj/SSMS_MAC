import Foundation
import NIOCore
import NIOPosix

/// Resolves the TCP port of a named SQL Server instance through the
/// SQL Server Browser service (UDP 1434).
public enum SQLBrowser {

    public static func resolvePort(host: String,
                                   instance: String,
                                   group: EventLoopGroup,
                                   timeout: TimeAmount = .seconds(5)) async throws -> Int {
        let response = try await queryBrowser(host: host, group: group, timeout: timeout)
        guard let port = parsePort(from: response, instance: instance) else {
            throw TDSError.instanceNotFound(
                "\(host)\\\(instance) — the SQL Server Browser did not report a TCP port for this instance.")
        }
        return port
    }

    /// Every instance the browser knows about, for the connection dialog's "Browse" list.
    public static func enumerateInstances(host: String,
                                          group: EventLoopGroup,
                                          timeout: TimeAmount = .seconds(5)) async throws -> [BrowserInstance] {
        let response = try await queryBrowser(host: host, group: group, timeout: timeout)
        return parseInstances(from: response)
    }

    public struct BrowserInstance: Sendable, Hashable {
        public var serverName: String
        public var instanceName: String
        public var version: String
        public var tcpPort: Int?
        public var isClustered: Bool
    }

    private final class BrowserHandler: ChannelInboundHandler {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        let promise: EventLoopPromise<String>
        init(promise: EventLoopPromise<String>) { self.promise = promise }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var envelope = unwrapInboundIn(data)
            guard let bytes = envelope.data.readBytes(length: envelope.data.readableBytes),
                  bytes.count > 3 else {
                promise.fail(TDSError.protocolError("empty SQL Browser response"))
                return
            }
            // 0x05, USHORT length, then MBCS payload
            let payload = Array(bytes.dropFirst(3))
            promise.succeed(String(decoding: payload, as: UTF8.self))
            context.close(promise: nil)
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            promise.fail(error)
            context.close(promise: nil)
        }
    }

    private static func queryBrowser(host: String,
                                     group: EventLoopGroup,
                                     timeout: TimeAmount) async throws -> String {
        let promise = group.next().makePromise(of: String.self)
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(BrowserHandler(promise: promise))
            }

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
        let scheduled = channel.eventLoop.scheduleTask(in: timeout) {
            promise.fail(TDSError.timeout("SQL Server Browser did not answer on UDP 1434"))
            channel.close(promise: nil)
        }

        do {
            let remote = try SocketAddress.makeAddressResolvingHost(host, port: 1434)
            var buffer = channel.allocator.buffer(capacity: 1)
            buffer.writeInteger(UInt8(0x02)) // CLNT_UCAST_EX: enumerate all instances
            try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: remote, data: buffer)).get()
            let result = try await promise.futureResult.get()
            scheduled.cancel()
            try? await channel.close().get()
            return result
        } catch {
            scheduled.cancel()
            try? await channel.close().get()
            throw error
        }
    }

    static func parseInstances(from response: String) -> [BrowserInstance] {
        var instances: [BrowserInstance] = []
        // Records are separated by ";;" and consist of key;value pairs.
        for record in response.components(separatedBy: ";;") where !record.isEmpty {
            let parts = record.components(separatedBy: ";")
            var dict: [String: String] = [:]
            var i = 0
            while i + 1 < parts.count {
                dict[parts[i].lowercased()] = parts[i + 1]
                i += 2
            }
            guard let name = dict["instancename"] else { continue }
            instances.append(BrowserInstance(
                serverName: dict["servername"] ?? "",
                instanceName: name,
                version: dict["version"] ?? "",
                tcpPort: dict["tcp"].flatMap { Int($0) },
                isClustered: (dict["isclustered"] ?? "No").lowercased() == "yes"
            ))
        }
        return instances
    }

    static func parsePort(from response: String, instance: String) -> Int? {
        parseInstances(from: response)
            .first { $0.instanceName.caseInsensitiveCompare(instance) == .orderedSame }?
            .tcpPort
    }
}
