import Foundation
import NIOCore

/// Encryption byte exchanged during PRELOGIN (MS-TDS 2.2.6.5).
public enum TDSEncryptionByte: UInt8, Sendable {
    /// Encryption is available but disabled; only the login packet is encrypted.
    case off = 0x00
    /// Encryption is available and enabled for the whole session.
    case on = 0x01
    /// Encryption is not supported by this endpoint.
    case notSupported = 0x02
    /// Encryption is required.
    case required = 0x03
    /// TDS 8.0 strict encryption (TLS before any TDS traffic).
    case clientCertificate = 0x04
}

public struct PreLoginRequest {
    public var version: (major: UInt8, minor: UInt8, build: UInt16, subBuild: UInt16)
    public var encryption: TDSEncryptionByte
    public var instanceName: String?
    public var threadID: UInt32
    public var mars: Bool
    public var federatedAuthRequired: Bool

    public init(encryption: TDSEncryptionByte,
                instanceName: String? = nil,
                threadID: UInt32 = 0,
                mars: Bool = false,
                federatedAuthRequired: Bool = false) {
        self.version = (16, 0, 1000, 0)
        self.encryption = encryption
        self.instanceName = instanceName
        self.threadID = threadID
        self.mars = mars
        self.federatedAuthRequired = federatedAuthRequired
    }

    private enum Token: UInt8 {
        case version = 0x00
        case encryption = 0x01
        case instOpt = 0x02
        case threadID = 0x03
        case mars = 0x04
        case traceID = 0x05
        case fedAuthRequired = 0x06
        case terminator = 0xFF
    }

    public func serialize(allocator: ByteBufferAllocator) -> ByteBuffer {
        var payloads: [(Token, [UInt8])] = []

        var versionBytes = [UInt8]()
        versionBytes.append(version.major)
        versionBytes.append(version.minor)
        versionBytes.append(UInt8(version.build >> 8))
        versionBytes.append(UInt8(version.build & 0xFF))
        versionBytes.append(UInt8(version.subBuild >> 8))
        versionBytes.append(UInt8(version.subBuild & 0xFF))
        payloads.append((.version, versionBytes))

        payloads.append((.encryption, [encryption.rawValue]))

        var inst = [UInt8]((instanceName ?? "").utf8)
        inst.append(0)
        payloads.append((.instOpt, inst))

        payloads.append((.threadID, [
            UInt8(threadID & 0xFF),
            UInt8((threadID >> 8) & 0xFF),
            UInt8((threadID >> 16) & 0xFF),
            UInt8((threadID >> 24) & 0xFF)
        ]))

        payloads.append((.mars, [mars ? 1 : 0]))

        if federatedAuthRequired {
            payloads.append((.fedAuthRequired, [1]))
        }

        // header: (token, offset UInt16BE, length UInt16BE) * n + terminator
        let headerLength = payloads.count * 5 + 1
        var buffer = allocator.buffer(capacity: headerLength + payloads.reduce(0) { $0 + $1.1.count })
        var offset = headerLength
        for (token, data) in payloads {
            buffer.writeInteger(token.rawValue)
            buffer.writeInteger(UInt16(offset), endianness: .big)
            buffer.writeInteger(UInt16(data.count), endianness: .big)
            offset += data.count
        }
        buffer.writeInteger(Token.terminator.rawValue)
        for (_, data) in payloads { buffer.writeBytes(data) }
        return buffer
    }
}

public struct PreLoginResponse {
    public var version: String = ""
    public var majorVersion: UInt8 = 0
    public var encryption: TDSEncryptionByte = .notSupported
    public var instanceValidity: UInt8 = 0
    public var mars: Bool = false
    public var federatedAuthRequired: Bool = false
    public var nonce: [UInt8]?

    public init(parsing buffer: ByteBuffer) throws {
        var head = buffer
        var options: [(UInt8, Int, Int)] = []

        while true {
            guard let token: UInt8 = head.readInteger() else {
                throw TDSError.protocolError("truncated PRELOGIN response header")
            }
            if token == 0xFF { break }
            guard let offset: UInt16 = head.readInteger(endianness: .big),
                  let length: UInt16 = head.readInteger(endianness: .big) else {
                throw TDSError.protocolError("truncated PRELOGIN option header")
            }
            options.append((token, Int(offset), Int(length)))
        }

        for (token, offset, length) in options {
            guard var slice = buffer.getSlice(at: buffer.readerIndex + offset, length: length) else { continue }
            switch token {
            case 0x00:
                if let major: UInt8 = slice.readInteger(),
                   let minor: UInt8 = slice.readInteger(),
                   let build: UInt16 = slice.readInteger(endianness: .big) {
                    majorVersion = major
                    version = "\(major).\(minor).\(build)"
                }
            case 0x01:
                if let value: UInt8 = slice.readInteger() {
                    encryption = TDSEncryptionByte(rawValue: value) ?? .notSupported
                }
            case 0x02:
                if let value: UInt8 = slice.readInteger() { instanceValidity = value }
            case 0x04:
                if let value: UInt8 = slice.readInteger() { mars = value == 1 }
            case 0x06:
                if let value: UInt8 = slice.readInteger() { federatedAuthRequired = value == 1 }
            case 0x07:
                nonce = slice.readBytes(length: length)
            default:
                break
            }
        }
    }
}
