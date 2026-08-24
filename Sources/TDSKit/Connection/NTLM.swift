import Foundation
import CryptoKit

/// Minimal NTLMv2 client used for Windows Authentication against SQL Server.
/// Only the three message exchange is implemented, which is what TDS needs.
public struct NTLMAuthenticator {
    public let username: String
    public let password: String
    public let domain: String
    public let workstation: String

    public init(username: String, password: String, domain: String, workstation: String) {
        self.username = username
        self.password = password
        self.domain = domain
        self.workstation = workstation
    }

    private static let signature: [UInt8] = Array("NTLMSSP\0".utf8)

    private enum Flags {
        static let negotiateUnicode: UInt32 = 0x0000_0001
        static let requestTarget: UInt32 = 0x0000_0004
        static let negotiateNTLM: UInt32 = 0x0000_0200
        static let negotiateAlwaysSign: UInt32 = 0x0000_8000
        static let negotiateExtendedSecurity: UInt32 = 0x0008_0000
        static let negotiate128: UInt32 = 0x2000_0000
        static let negotiate56: UInt32 = 0x8000_0000
    }

    /// NTLM type 1 message.
    public func negotiateMessage() -> [UInt8] {
        var out = NTLMAuthenticator.signature
        out.append(contentsOf: le32(1)) // message type
        let flags = Flags.negotiateUnicode | Flags.requestTarget | Flags.negotiateNTLM
            | Flags.negotiateAlwaysSign | Flags.negotiateExtendedSecurity
            | Flags.negotiate128 | Flags.negotiate56
        out.append(contentsOf: le32(flags))
        out.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // domain (empty)
        out.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // workstation (empty)
        return out
    }

    /// NTLM type 3 message, computed from the server's type 2 challenge.
    public func authenticateMessage(challenge message: [UInt8]) throws -> [UInt8] {
        guard message.count >= 32, Array(message.prefix(8)) == NTLMAuthenticator.signature else {
            throw TDSError.protocolError("malformed NTLM challenge from the server")
        }
        let serverChallenge = Array(message[24..<32])
        let flags = readLE32(message, at: 20)

        var targetInfo: [UInt8] = []
        if message.count >= 48 {
            let len = Int(readLE16(message, at: 40))
            let offset = Int(readLE32(message, at: 44))
            if offset + len <= message.count, len > 0 {
                targetInfo = Array(message[offset..<(offset + len)])
            }
        }

        let ntlmV2Hash = NTLMAuthenticator.ntowfv2(password: password,
                                                   user: username,
                                                   domain: domain)
        var clientChallenge = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { clientChallenge[i] = UInt8.random(in: 0...255) }

        // Windows FILETIME: 100 ns ticks since 1601-01-01.
        let unixSeconds = Date().timeIntervalSince1970
        let filetime = UInt64((unixSeconds + 11_644_473_600) * 10_000_000)

        var blob: [UInt8] = [0x01, 0x01, 0x00, 0x00]
        blob.append(contentsOf: [0, 0, 0, 0])
        blob.append(contentsOf: le64(filetime))
        blob.append(contentsOf: clientChallenge)
        blob.append(contentsOf: [0, 0, 0, 0])
        blob.append(contentsOf: targetInfo)
        blob.append(contentsOf: [0, 0, 0, 0])

        var proofInput = serverChallenge
        proofInput.append(contentsOf: blob)
        let ntProof = NTLMAuthenticator.hmacMD5(key: ntlmV2Hash, data: proofInput)
        let ntResponse = ntProof + blob

        var lmInput = serverChallenge
        lmInput.append(contentsOf: clientChallenge)
        let lmResponse = NTLMAuthenticator.hmacMD5(key: ntlmV2Hash, data: lmInput) + clientChallenge

        let domainBytes = utf16le(domain)
        let userBytes = utf16le(username)
        let workstationBytes = utf16le(workstation)
        let sessionKey: [UInt8] = []

        var payloadOffset = 64 + 8 // header + MIC-less; NTLM type 3 header is 64 bytes (+8 for version)
        payloadOffset = 72

        var out = NTLMAuthenticator.signature
        out.append(contentsOf: le32(3))

        func field(_ bytes: [UInt8]) -> [UInt8] {
            var f = le16(UInt16(bytes.count))
            f.append(contentsOf: le16(UInt16(bytes.count)))
            f.append(contentsOf: le32(UInt32(payloadOffset)))
            payloadOffset += bytes.count
            return f
        }

        let lmField = field(lmResponse)
        let ntField = field(ntResponse)
        let domainField = field(domainBytes)
        let userField = field(userBytes)
        let workstationField = field(workstationBytes)
        let sessionField = field(sessionKey)

        out.append(contentsOf: lmField)
        out.append(contentsOf: ntField)
        out.append(contentsOf: domainField)
        out.append(contentsOf: userField)
        out.append(contentsOf: workstationField)
        out.append(contentsOf: sessionField)
        out.append(contentsOf: le32(flags))
        out.append(contentsOf: [10, 0, 0, 0, 0, 0, 0, 15]) // version block

        out.append(contentsOf: lmResponse)
        out.append(contentsOf: ntResponse)
        out.append(contentsOf: domainBytes)
        out.append(contentsOf: userBytes)
        out.append(contentsOf: workstationBytes)
        out.append(contentsOf: sessionKey)
        return out
    }

    // MARK: - Crypto helpers

    static func ntowfv2(password: String, user: String, domain: String) -> [UInt8] {
        let md4 = MD4.hash(bytes: utf16leBytes(password))
        let identity = utf16leBytes(user.uppercased() + domain)
        return hmacMD5(key: md4, data: identity)
    }

    static func hmacMD5(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let symmetricKey = SymmetricKey(data: Data(key))
        var mac = HMAC<Insecure.MD5>(key: symmetricKey)
        mac.update(data: Data(data))
        return Array(mac.finalize())
    }

    static func utf16leBytes(_ string: String) -> [UInt8] {
        var out = [UInt8]()
        for unit in string.utf16 {
            out.append(UInt8(unit & 0xFF))
            out.append(UInt8(unit >> 8))
        }
        return out
    }
}

private func utf16le(_ string: String) -> [UInt8] { NTLMAuthenticator.utf16leBytes(string) }
private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}
private func le64(_ v: UInt64) -> [UInt8] {
    (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }
}
private func readLE16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    guard offset + 1 < bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}
private func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    guard offset + 3 < bytes.count else { return 0 }
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
}

/// MD4 – required by NTLM and absent from CryptoKit.
enum MD4 {
    static func hash(bytes input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(input.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in 0..<8 { message.append(UInt8((bitLength >> (8 * UInt64(i))) & 0xFF)) }

        var a: UInt32 = 0x6745_2301
        var b: UInt32 = 0xEFCD_AB89
        var c: UInt32 = 0x98BA_DCFE
        var d: UInt32 = 0x1032_5476

        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

        var block = 0
        while block < message.count {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = block + i * 4
                x[i] = UInt32(message[o]) | (UInt32(message[o + 1]) << 8)
                    | (UInt32(message[o + 2]) << 16) | (UInt32(message[o + 3]) << 24)
            }
            let (aa, bb, cc, dd) = (a, b, c, d)

            let round1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
            let shift1: [UInt32] = [3, 7, 11, 19]
            for i in 0..<16 {
                let k = round1[i]
                let s = shift1[i % 4]
                switch i % 4 {
                case 0: a = rotl(a &+ ((b & c) | (~b & d)) &+ x[k], s)
                case 1: d = rotl(d &+ ((a & b) | (~a & c)) &+ x[k], s)
                case 2: c = rotl(c &+ ((d & a) | (~d & b)) &+ x[k], s)
                default: b = rotl(b &+ ((c & d) | (~c & a)) &+ x[k], s)
                }
            }

            let round2 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
            let shift2: [UInt32] = [3, 5, 9, 13]
            for i in 0..<16 {
                let k = round2[i]
                let s = shift2[i % 4]
                switch i % 4 {
                case 0: a = rotl(a &+ ((b & c) | (b & d) | (c & d)) &+ x[k] &+ 0x5A82_7999, s)
                case 1: d = rotl(d &+ ((a & b) | (a & c) | (b & c)) &+ x[k] &+ 0x5A82_7999, s)
                case 2: c = rotl(c &+ ((d & a) | (d & b) | (a & b)) &+ x[k] &+ 0x5A82_7999, s)
                default: b = rotl(b &+ ((c & d) | (c & a) | (d & a)) &+ x[k] &+ 0x5A82_7999, s)
                }
            }

            let round3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
            let shift3: [UInt32] = [3, 9, 11, 15]
            for i in 0..<16 {
                let k = round3[i]
                let s = shift3[i % 4]
                switch i % 4 {
                case 0: a = rotl(a &+ (b ^ c ^ d) &+ x[k] &+ 0x6ED9_EBA1, s)
                case 1: d = rotl(d &+ (a ^ b ^ c) &+ x[k] &+ 0x6ED9_EBA1, s)
                case 2: c = rotl(c &+ (d ^ a ^ b) &+ x[k] &+ 0x6ED9_EBA1, s)
                default: b = rotl(b &+ (c ^ d ^ a) &+ x[k] &+ 0x6ED9_EBA1, s)
                }
            }

            a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
            block += 64
        }

        var digest = [UInt8]()
        for value in [a, b, c, d] {
            for i in 0..<4 { digest.append(UInt8((value >> (8 * UInt32(i))) & 0xFF)) }
        }
        return digest
    }
}
