import Foundation
import NIOCore

extension ByteBuffer {

    // MARK: - Reading

    /// UCS-2 / UTF-16LE string of `charCount` characters.
    mutating func readUCS2String(charCount: Int) -> String? {
        guard charCount >= 0, let bytes = readBytes(length: charCount * 2) else { return nil }
        return ByteBuffer.decodeUTF16LE(bytes)
    }

    static func decodeUTF16LE(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        var units = [UInt16]()
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            units.append(UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// B_VARCHAR: one byte character count followed by UCS-2 characters.
    mutating func readBVarchar() -> String? {
        guard let count: UInt8 = readInteger() else { return nil }
        return readUCS2String(charCount: Int(count))
    }

    /// US_VARCHAR: two byte (little endian) character count followed by UCS-2 characters.
    mutating func readUSVarchar() -> String? {
        guard let count: UInt16 = readInteger(endianness: .little) else { return nil }
        return readUCS2String(charCount: Int(count))
    }

    /// B_VARBYTE: one byte length followed by raw bytes.
    mutating func readBVarbyte() -> [UInt8]? {
        guard let count: UInt8 = readInteger() else { return nil }
        return readBytes(length: Int(count))
    }

    /// US_VARBYTE: two byte length followed by raw bytes.
    mutating func readUSVarbyte() -> [UInt8]? {
        guard let count: UInt16 = readInteger(endianness: .little) else { return nil }
        return readBytes(length: Int(count))
    }

    mutating func readCollation() -> TDSCollation? {
        guard let raw: UInt32 = readInteger(endianness: .little),
              let sortID: UInt8 = readInteger() else { return nil }
        return TDSCollation(raw: raw, sortId: sortID)
    }

    // MARK: - Writing

    @discardableResult
    mutating func writeUCS2String(_ string: String) -> Int {
        var written = 0
        for unit in string.utf16 {
            written += writeInteger(unit, endianness: .little)
        }
        return written
    }

    @discardableResult
    mutating func writeBVarchar(_ string: String) -> Int {
        let units = Array(string.utf16)
        var written = writeInteger(UInt8(min(units.count, 255)))
        for unit in units.prefix(255) { written += writeInteger(unit, endianness: .little) }
        return written
    }

    @discardableResult
    mutating func writeUSVarchar(_ string: String) -> Int {
        let units = Array(string.utf16)
        var written = writeInteger(UInt16(units.count), endianness: .little)
        for unit in units { written += writeInteger(unit, endianness: .little) }
        return written
    }

    /// Number of UTF-16 code units – TDS counts characters, not bytes.
    static func ucs2Length(_ string: String) -> Int { string.utf16.count }
}

extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
