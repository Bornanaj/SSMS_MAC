import Foundation
import NIOCore

/// TDS packet types (MS-TDS 2.2.3.1.1).
public enum TDSPacketType: UInt8, Sendable {
    case sqlBatch = 0x01
    case preTDS7Login = 0x02
    case rpc = 0x03
    case tabularResult = 0x04
    case attention = 0x06
    case bulkLoadData = 0x07
    case federatedAuthToken = 0x08
    case transactionManager = 0x0E
    case tds7Login = 0x10
    case sspi = 0x11
    case preLogin = 0x12
}

public struct TDSPacketStatus: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let normal = TDSPacketStatus([])
    public static let endOfMessage = TDSPacketStatus(rawValue: 0x01)
    public static let ignore = TDSPacketStatus(rawValue: 0x02)
    public static let resetConnection = TDSPacketStatus(rawValue: 0x08)
    public static let resetConnectionSkipTran = TDSPacketStatus(rawValue: 0x10)
}

/// One framed TDS packet as it appears on the wire.
public struct TDSPacket: Sendable {
    public static let headerLength = 8
    public static let defaultPacketSize = 4096
    public static let maxPacketSize = 32767
    public static let minPacketSize = 512

    public var type: TDSPacketType
    public var status: TDSPacketStatus
    public var spid: UInt16
    public var packetID: UInt8
    public var window: UInt8
    public var payload: ByteBuffer

    public init(type: TDSPacketType, status: TDSPacketStatus, spid: UInt16 = 0,
                packetID: UInt8 = 1, window: UInt8 = 0, payload: ByteBuffer) {
        self.type = type
        self.status = status
        self.spid = spid
        self.packetID = packetID
        self.window = window
        self.payload = payload
    }

    public var isEndOfMessage: Bool { status.contains(.endOfMessage) }
}

/// A complete logical message: a packet type plus the payload assembled from
/// however many packets the server or client needed.
public struct TDSMessage: Sendable {
    public var type: TDSPacketType
    public var payload: ByteBuffer
    /// Set on the first packet of a request to make the server reset session state.
    public var resetConnection: Bool

    public init(type: TDSPacketType, payload: ByteBuffer, resetConnection: Bool = false) {
        self.type = type
        self.payload = payload
        self.resetConnection = resetConnection
    }
}

/// Splits an incoming byte stream into `TDSPacket`s.
public struct TDSPacketDecoder: ByteToMessageDecoder {
    public typealias InboundOut = TDSPacket

    public init() {}

    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= TDSPacket.headerLength else { return .needMoreData }

        let saved = buffer.readerIndex
        guard
            let rawType: UInt8 = buffer.getInteger(at: saved),
            let rawStatus: UInt8 = buffer.getInteger(at: saved + 1),
            let length: UInt16 = buffer.getInteger(at: saved + 2, endianness: .big),
            let spid: UInt16 = buffer.getInteger(at: saved + 4, endianness: .big),
            let packetID: UInt8 = buffer.getInteger(at: saved + 6),
            let window: UInt8 = buffer.getInteger(at: saved + 7)
        else { return .needMoreData }

        guard length >= UInt16(TDSPacket.headerLength) else {
            throw TDSError.protocolError("packet length \(length) is smaller than the header")
        }
        let total = Int(length)
        guard buffer.readableBytes >= total else { return .needMoreData }

        buffer.moveReaderIndex(forwardBy: TDSPacket.headerLength)
        let payloadLength = total - TDSPacket.headerLength
        guard let payload = buffer.readSlice(length: payloadLength) else { return .needMoreData }

        guard let type = TDSPacketType(rawValue: rawType) else {
            throw TDSError.protocolError(String(format: "unknown packet type 0x%02X", rawType))
        }

        context.fireChannelRead(wrapInboundOut(TDSPacket(
            type: type,
            status: TDSPacketStatus(rawValue: rawStatus),
            spid: spid,
            packetID: packetID,
            window: window,
            payload: payload
        )))
        return .continue
    }

    public mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer,
                                    seenEOF: Bool) throws -> DecodingState {
        if buffer.readableBytes > 0 {
            return try decode(context: context, buffer: &buffer)
        }
        return .needMoreData
    }
}

/// Fragments an outbound `TDSMessage` into correctly sized packets.
///
/// Each packet is written and flushed on its own. That matters once TLS is in play:
/// SQL Server negotiates encryption by wrapping the handshake in PRELOGIN packets and
/// then keeps reading one TDS packet per TLS record, so batching several packets into
/// a single record makes the server drop the connection. Flushing per packet keeps the
/// one-to-one mapping every other TDS driver relies on.
final class TDSPacketWriter: ChannelOutboundHandler {
    typealias OutboundIn = TDSMessage
    typealias OutboundOut = ByteBuffer

    /// Negotiated packet size; updated by ENVCHANGE type 4.
    var packetSize: Int = TDSPacket.defaultPacketSize

    private static let debugEnabled = ProcessInfo.processInfo.environment["TDS_DEBUG"] != nil

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        var payload = message.payload
        let maxPayload = max(packetSize - TDSPacket.headerLength, 128)
        var packetID: UInt8 = 1

        if payload.readableBytes == 0 {
            var status = TDSPacketStatus.endOfMessage
            if message.resetConnection { status.insert(.resetConnection) }
            var buffer = context.channel.allocator.buffer(capacity: TDSPacket.headerLength)
            writeHeader(type: message.type, status: status, payloadLength: 0,
                        packetID: packetID, into: &buffer)
            context.write(wrapOutboundOut(buffer), promise: promise)
            context.flush()
            return
        }

        var first = true
        while payload.readableBytes > 0 {
            let chunkLength = min(maxPayload, payload.readableBytes)
            guard let chunk = payload.readSlice(length: chunkLength) else { break }
            var status = TDSPacketStatus.normal
            let isLast = payload.readableBytes == 0
            if isLast { status.insert(.endOfMessage) }
            if first && message.resetConnection { status.insert(.resetConnection) }

            var buffer = context.channel.allocator.buffer(
                capacity: chunkLength + TDSPacket.headerLength)
            writeHeader(type: message.type, status: status, payloadLength: chunkLength,
                        packetID: packetID, into: &buffer)
            buffer.writeImmutableBuffer(chunk)

            if TDSPacketWriter.debugEnabled {
                let line = "[tds] out type=\(message.type) id=\(packetID) len=\(chunkLength) eom=\(isLast) remaining=\(payload.readableBytes)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }

            context.write(wrapOutboundOut(buffer), promise: isLast ? promise : nil)
            context.flush()

            packetID = packetID == 255 ? 1 : packetID &+ 1
            first = false
        }
    }

    private func writeHeader(type: TDSPacketType, status: TDSPacketStatus,
                             payloadLength: Int, packetID: UInt8, into out: inout ByteBuffer) {
        out.writeInteger(type.rawValue)
        out.writeInteger(status.rawValue)
        out.writeInteger(UInt16(payloadLength + TDSPacket.headerLength), endianness: .big)
        out.writeInteger(UInt16(0), endianness: .big) // SPID
        out.writeInteger(packetID)
        out.writeInteger(UInt8(0)) // Window
    }
}
