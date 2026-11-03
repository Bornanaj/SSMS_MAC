import Foundation
import NIOCore
import NIOTLS

/// Events surfaced to callers while a request streams back.
public enum TDSStreamEvent: Sendable {
    case columns([TDSColumn])
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
    case sspi([UInt8])
    case fedAuthInfo(stsURL: String, spn: String)
    case featureExtAck([UInt8: [UInt8]])
    case order([Int])
}

/// Wraps the TLS handshake in PRELOGIN packets, which is how SQL Server
/// negotiates transport security (MS-TDS 2.2.6.5). Once the handshake finishes
/// the handler becomes a pass-through and normal TDS packets travel inside TLS.
final class TDSTLSHandshakeWrapper: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var handshakeComplete = false
    private var pending: ByteBuffer?
    private let maxPayload = 4088

    func markHandshakeComplete() {
        handshakeComplete = true
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if handshakeComplete {
            context.write(data, promise: promise)
            return
        }
        var input = unwrapOutboundIn(data)
        var out = context.channel.allocator.buffer(capacity: input.readableBytes + 16)
        while input.readableBytes > 0 {
            let length = min(maxPayload, input.readableBytes)
            guard let chunk = input.readSlice(length: length) else { break }
            out.writeInteger(TDSPacketType.preLogin.rawValue)
            out.writeInteger(TDSPacketStatus.endOfMessage.rawValue)
            out.writeInteger(UInt16(chunk.readableBytes + TDSPacket.headerLength), endianness: .big)
            out.writeInteger(UInt16(0), endianness: .big)
            out.writeInteger(UInt8(1))
            out.writeInteger(UInt8(0))
            out.writeImmutableBuffer(chunk)
        }
        context.write(wrapOutboundOut(out), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if handshakeComplete, pending == nil {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        if pending == nil {
            pending = incoming
        } else {
            pending!.writeBuffer(&incoming)
        }

        var output = context.channel.allocator.buffer(capacity: pending!.readableBytes)
        while var buffer = pending {
            if handshakeComplete {
                // Everything from here on is raw TLS traffic.
                if buffer.readableBytes > 0 { output.writeBuffer(&buffer) }
                pending = nil
                break
            }
            guard buffer.readableBytes >= TDSPacket.headerLength,
                  let length: UInt16 = buffer.getInteger(at: buffer.readerIndex + 2, endianness: .big),
                  buffer.readableBytes >= Int(length) else {
                pending = buffer
                break
            }
            buffer.moveReaderIndex(forwardBy: TDSPacket.headerLength)
            if let payload = buffer.readSlice(length: Int(length) - TDSPacket.headerLength) {
                output.writeImmutableBuffer(payload)
            }
            pending = buffer.readableBytes > 0 ? buffer : nil
        }

        if output.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(output))
        }
    }
}

/// Sits directly above the TLS handler and tells the wrapper below when the
/// handshake finished, because user events only travel away from the network.
final class TDSTLSCompletionNotifier: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let wrapper: TDSTLSHandshakeWrapper
    private let onComplete: () -> Void
    private var fired = false

    init(wrapper: TDSTLSHandshakeWrapper, onComplete: @escaping () -> Void) {
        self.wrapper = wrapper
        self.onComplete = onComplete
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent, !fired {
            fired = true
            wrapper.markHandshakeComplete()
            onComplete()
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// Drives one request/response exchange at a time and turns inbound packets into
/// either a raw payload (PRELOGIN) or a stream of parsed tokens.
final class TDSConnectionHandler: ChannelDuplexHandler {
    typealias InboundIn = TDSPacket
    typealias InboundOut = Never
    typealias OutboundIn = TDSMessage
    typealias OutboundOut = TDSMessage

    enum Pending {
        case raw(EventLoopPromise<ByteBuffer>)
        case tokens(sink: (TDSStreamEvent) -> Void, promise: EventLoopPromise<Void>)
    }

    private var pending: Pending?
    private var accumulator: ByteBuffer
    private var parser = TDSTokenStreamParser()
    private var context: ChannelHandlerContext?
    private var closed = false
    private var closeReason: String = "the server closed the connection"

    /// Updated when the server announces a different packet size.
    var onPacketSizeChange: ((Int) -> Void)?
    /// How many bytes the accumulator must hold before a parse that came up short is
    /// tried again. A token split across packets is re-parsed from its start whenever
    /// more arrives, which copied a 16 MB value once per 4 KB packet; waiting until
    /// the buffer has doubled keeps the total work linear. The end of the message
    /// always parses, so nothing waits for data it does not need.
    private var retryThreshold = 0

    init(allocator: ByteBufferAllocator) {
        self.accumulator = allocator.buffer(capacity: 16 * 1024)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func beginRaw(promise: EventLoopPromise<ByteBuffer>) {
        pending = .raw(promise)
        accumulator.clear()
    }

    func beginTokens(sink: @escaping (TDSStreamEvent) -> Void, promise: EventLoopPromise<Void>) {
        parser.reset()
        accumulator.clear()
        retryThreshold = 0
        pending = .tokens(sink: sink, promise: promise)
    }

    var isBusy: Bool { pending != nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var packet = unwrapInboundIn(data)
        guard let current = pending else { return }

        switch current {
        case .raw(let promise):
            accumulator.writeBuffer(&packet.payload)
            if packet.isEndOfMessage {
                pending = nil
                let result = accumulator
                accumulator.clear()
                promise.succeed(result)
            }

        case .tokens(let sink, let promise):
            accumulator.writeBuffer(&packet.payload)
            if !packet.isEndOfMessage && accumulator.readableBytes < retryThreshold { return }
            do {
                try parser.parse(&accumulator) { token in
                    switch token {
                    case .columnMetadata(let cols): sink(.columns(cols))
                    case .row(let values): sink(.row(values))
                    case .done(let info): sink(.done(info))
                    case .doneProc(let info): sink(.doneProc(info))
                    case .doneInProc(let info): sink(.doneInProc(info))
                    case .info(let m): sink(.info(m))
                    case .error(let m): sink(.error(m))
                    case .envChange(let change):
                        if case .packetSize(let new, _) = change { onPacketSizeChange?(new) }
                        sink(.envChange(change))
                    case .loginAck(let ack): sink(.loginAck(ack))
                    case .returnStatus(let s): sink(.returnStatus(s))
                    case .returnValue(let v): sink(.returnValue(v))
                    case .order(let o): sink(.order(o))
                    case .sspi(let bytes): sink(.sspi(bytes))
                    case .fedAuthInfo(let url, let spn): sink(.fedAuthInfo(stsURL: url, spn: spn))
                    case .featureExtAck(let acks): sink(.featureExtAck(acks))
                    case .tableName, .sessionState: break
                    }
                }
                // Whatever is left is the front of a token that is not complete yet.
                let leftover = accumulator.readableBytes
                retryThreshold = leftover > 0 ? leftover * 2 : 0
                accumulator.discardReadBytes()
            } catch {
                pending = nil
                promise.fail(error)
                context.close(promise: nil)
                return
            }
            if packet.isEndOfMessage {
                pending = nil
                accumulator.clear()
                promise.succeed(())
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failPending(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed = true
        failPending(TDSError.connectionClosed(reason: closeReason))
        context.fireChannelInactive()
    }

    func failPending(_ error: Error) {
        guard let current = pending else { return }
        pending = nil
        switch current {
        case .raw(let promise): promise.fail(error)
        case .tokens(_, let promise): promise.fail(error)
        }
    }
}
