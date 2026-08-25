import Foundation
import NIOCore

/// TDS protocol versions we can speak.
public enum TDSVersion: UInt32, Sendable, Comparable {
    case v7_1 = 0x71000001 // SQL Server 2000 SP1
    case v7_2 = 0x72090002 // SQL Server 2005
    case v7_3 = 0x730B0003 // SQL Server 2008 R2
    case v7_4 = 0x74000004 // SQL Server 2012+

    public static func < (lhs: TDSVersion, rhs: TDSVersion) -> Bool { lhs.rawValue < rhs.rawValue }

    public var supportsDateTime2: Bool { self >= .v7_3 }
}

/// FeatureExt identifiers (MS-TDS 2.2.6.4).
public enum TDSFeatureID: UInt8, Sendable {
    case sessionRecovery = 0x01
    case fedAuth = 0x02
    case columnEncryption = 0x04
    case globalTransactions = 0x05
    case azureSQLSupport = 0x08
    case dataClassification = 0x09
    case utf8Support = 0x0A
    case azureSQLDNSCaching = 0x0B
    case terminator = 0xFF
}

public struct Login7Request {
    public var tdsVersion: TDSVersion = .v7_4
    public var packetSize: UInt32 = UInt32(TDSPacket.defaultPacketSize)
    public var clientProgramVersion: UInt32 = 0x0100_0000
    public var clientPID: UInt32 = UInt32(ProcessInfo.processInfo.processIdentifier)
    public var connectionID: UInt32 = 0

    public var hostName: String = ""
    public var userName: String = ""
    public var password: String = ""
    public var appName: String = "SSMS for Mac"
    public var serverName: String = ""
    public var clientInterfaceName: String = "TDSKit"
    public var language: String = ""
    public var database: String = ""
    public var attachDBFile: String = ""
    public var changePassword: String = ""

    public var useIntegratedSecurity = false
    public var sspiPayload: [UInt8] = []

    public var readOnlyIntent = false
    public var initialDatabaseFatal = true
    public var initialLanguageFatal = true
    public var useODBCDefaults = true
    public var enableUTF8 = false
    public var fedAuthToken: String?
    public var fedAuthNonce: [UInt8]?
    public var clientTimeZoneMinutes: Int32 = 0
    public var clientLCID: UInt32 = 0x0409 // en-US; affects server-side language of messages only

    public init() {}

    private var needsFeatureExt: Bool { enableUTF8 || fedAuthToken != nil }

    public func serialize(allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: 512)

        // ---- variable length payloads, in the order the wire wants them ----
        struct Field { let offsetSlot: Int; let bytes: [UInt8]; let charCount: Int }

        func ucs2(_ s: String) -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(s.utf16.count * 2)
            for u in s.utf16 {
                out.append(UInt8(u & 0xFF))
                out.append(UInt8(u >> 8))
            }
            return out
        }

        let hostBytes = ucs2(hostName)
        let userBytes = useIntegratedSecurity ? [] : ucs2(userName)
        let passwordBytes = useIntegratedSecurity ? [] : Login7Request.obfuscate(ucs2(password))
        let appBytes = ucs2(appName)
        let serverBytes = ucs2(serverName)
        let cltIntBytes = ucs2(clientInterfaceName)
        let langBytes = ucs2(language)
        let dbBytes = ucs2(database)
        let atchBytes = ucs2(attachDBFile)
        let changePwdBytes = changePassword.isEmpty ? [] : Login7Request.obfuscate(ucs2(changePassword))
        let featureExt: [UInt8] = needsFeatureExt ? buildFeatureExt() : []

        let fixedLength = 94
        // Layout: fixed header, then variable data, feature ext last.
        var dataOffset = fixedLength
        if needsFeatureExt { dataOffset += 4 } // the DWORD that ibExtension points at

        func reserve(_ bytes: [UInt8]) -> (offset: Int, count: Int) {
            let o = dataOffset
            dataOffset += bytes.count
            return (o, bytes.count)
        }

        let host = reserve(hostBytes)
        let user = reserve(userBytes)
        let pass = reserve(passwordBytes)
        let app = reserve(appBytes)
        let server = reserve(serverBytes)
        let cltInt = reserve(cltIntBytes)
        let lang = reserve(langBytes)
        let db = reserve(dbBytes)
        let atch = reserve(atchBytes)
        let changePwd = reserve(changePwdBytes)
        let sspi = reserve(sspiPayload)
        let featureOffset = dataOffset
        dataOffset += featureExt.count

        let totalLength = dataOffset

        // ---- fixed header ----
        body.writeInteger(UInt32(totalLength), endianness: .little)
        body.writeInteger(tdsVersion.rawValue, endianness: .little)
        body.writeInteger(packetSize, endianness: .little)
        body.writeInteger(clientProgramVersion, endianness: .little)
        body.writeInteger(clientPID, endianness: .little)
        body.writeInteger(connectionID, endianness: .little)

        var flags1: UInt8 = 0x00
        flags1 |= 0x20 // fUseDB: notify us with ENVCHANGE when the database changes
        if initialDatabaseFatal { flags1 |= 0x40 }
        if initialLanguageFatal { flags1 |= 0x80 }
        body.writeInteger(flags1)

        var flags2: UInt8 = 0x00
        if initialLanguageFatal { flags2 |= 0x01 }
        if useODBCDefaults { flags2 |= 0x02 } // sets ANSI defaults, like SSMS does
        if useIntegratedSecurity { flags2 |= 0x80 }
        body.writeInteger(flags2)

        var typeFlags: UInt8 = 0x00
        if readOnlyIntent { typeFlags |= 0x20 }
        body.writeInteger(typeFlags)

        var flags3: UInt8 = 0x08 // fUnknownCollationHandling – required for TDS 7.4
        if needsFeatureExt { flags3 |= 0x10 }
        body.writeInteger(flags3)

        body.writeInteger(clientTimeZoneMinutes, endianness: .little)
        body.writeInteger(clientLCID, endianness: .little)

        func writeSlot(_ field: (offset: Int, count: Int), chars: Int) {
            body.writeInteger(UInt16(field.count == 0 ? 0 : field.offset), endianness: .little)
            body.writeInteger(UInt16(chars), endianness: .little)
        }

        writeSlot(host, chars: hostName.utf16.count)
        writeSlot(user, chars: useIntegratedSecurity ? 0 : userName.utf16.count)
        writeSlot(pass, chars: useIntegratedSecurity ? 0 : password.utf16.count)
        writeSlot(app, chars: appName.utf16.count)
        writeSlot(server, chars: serverName.utf16.count)

        // ibExtension / cbExtension
        if needsFeatureExt {
            body.writeInteger(UInt16(fixedLength), endianness: .little)
            body.writeInteger(UInt16(4), endianness: .little)
        } else {
            body.writeInteger(UInt16(0), endianness: .little)
            body.writeInteger(UInt16(0), endianness: .little)
        }

        writeSlot(cltInt, chars: clientInterfaceName.utf16.count)
        writeSlot(lang, chars: language.utf16.count)
        writeSlot(db, chars: database.utf16.count)

        body.writeBytes([0x00, 0x50, 0x56, 0x4D, 0x41, 0x43]) // ClientID (fake MAC)

        body.writeInteger(UInt16(sspiPayload.isEmpty ? 0 : sspi.offset), endianness: .little)
        body.writeInteger(UInt16(sspiPayload.count > 65535 ? 65535 : sspiPayload.count), endianness: .little)

        writeSlot(atch, chars: attachDBFile.utf16.count)
        writeSlot(changePwd, chars: changePassword.utf16.count)

        body.writeInteger(UInt32(sspiPayload.count > 65535 ? sspiPayload.count : 0), endianness: .little)

        // ---- variable data ----
        if needsFeatureExt {
            body.writeInteger(UInt32(featureOffset), endianness: .little)
        }
        body.writeBytes(hostBytes)
        body.writeBytes(userBytes)
        body.writeBytes(passwordBytes)
        body.writeBytes(appBytes)
        body.writeBytes(serverBytes)
        body.writeBytes(cltIntBytes)
        body.writeBytes(langBytes)
        body.writeBytes(dbBytes)
        body.writeBytes(atchBytes)
        body.writeBytes(changePwdBytes)
        body.writeBytes(sspiPayload)
        body.writeBytes(featureExt)

        return body
    }

    private func buildFeatureExt() -> [UInt8] {
        var out = [UInt8]()

        if let token = fedAuthToken {
            var data = [UInt8]()
            // bFedAuthLibrary = 0x01 (Security Token), fFedAuthEcho = 0
            data.append(0x01 << 1)
            var tokenBytes = [UInt8]()
            for u in token.utf16 {
                tokenBytes.append(UInt8(u & 0xFF))
                tokenBytes.append(UInt8(u >> 8))
            }
            let len = UInt32(tokenBytes.count)
            data.append(contentsOf: [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF),
                                     UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF)])
            data.append(contentsOf: tokenBytes)
            if let nonce = fedAuthNonce { data.append(contentsOf: nonce) }

            out.append(TDSFeatureID.fedAuth.rawValue)
            let dl = UInt32(data.count)
            out.append(contentsOf: [UInt8(dl & 0xFF), UInt8((dl >> 8) & 0xFF),
                                    UInt8((dl >> 16) & 0xFF), UInt8((dl >> 24) & 0xFF)])
            out.append(contentsOf: data)
        }

        if enableUTF8 {
            out.append(TDSFeatureID.utf8Support.rawValue)
            out.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            out.append(0x00)
        }

        out.append(TDSFeatureID.terminator.rawValue)
        return out
    }

    /// The classic TDS password scramble: swap nibbles, then XOR with 0xA5.
    public static func obfuscate(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { b in
            let swapped = (b << 4) | (b >> 4)
            return swapped ^ 0xA5
        }
    }
}
