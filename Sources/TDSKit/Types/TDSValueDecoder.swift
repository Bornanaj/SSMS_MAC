import Foundation
import NIOCore

public enum TDSValueDecoder {

    /// Decode one column value from a ROW token payload.
    public static func readValue(type info: TDSTypeInfo, from buffer: inout ByteBuffer) throws -> TDSValue {
        if info.usesPLP {
            guard let bytes = try readPLP(from: &buffer) else { return .null }
            return decodeBytes(bytes, info: info)
        }

        switch info.dataType.lengthKind {
        case .zero:
            return .null

        case .fixed(let n):
            guard let bytes = buffer.readBytes(length: n) else {
                throw TDSNeedMoreData()
            }
            return decodeBytes(bytes, info: info)

        case .byteLen:
            guard let len: UInt8 = buffer.readInteger() else {
                throw TDSNeedMoreData()
            }
            if len == 0 || len == 0xFF && isLegacyNullable(info.dataType) { return .null }
            guard let bytes = buffer.readBytes(length: Int(len)) else {
                throw TDSNeedMoreData()
            }
            return decodeBytes(bytes, info: info)

        case .ushortLen:
            guard let len: UInt16 = buffer.readInteger(endianness: .little) else {
                throw TDSNeedMoreData()
            }
            if len == 0xFFFF { return .null }
            guard let bytes = buffer.readBytes(length: Int(len)) else {
                throw TDSNeedMoreData()
            }
            return decodeBytes(bytes, info: info)

        case .longLen:
            guard let ptrLen: UInt8 = buffer.readInteger() else {
                throw TDSNeedMoreData()
            }
            if ptrLen == 0 { return .null }
            guard buffer.readBytes(length: Int(ptrLen)) != nil,
                  buffer.readBytes(length: 8) != nil, // timestamp
                  let dataLen: Int32 = buffer.readInteger(endianness: .little) else {
                throw TDSNeedMoreData()
            }
            if dataLen < 0 { return .null }
            guard let bytes = buffer.readBytes(length: Int(dataLen)) else {
                throw TDSNeedMoreData()
            }
            return decodeBytes(bytes, info: info)

        case .variantLen:
            return try readVariant(from: &buffer)

        case .plpOnly:
            // handled by the usesPLP branch above
            guard let bytes = try readPLP(from: &buffer) else { return .null }
            return decodeBytes(bytes, info: info)
        }
    }

    private static func isLegacyNullable(_ type: TDSDataType) -> Bool {
        switch type {
        case .charLegacy, .varCharLegacy, .binaryLegacy, .varBinaryLegacy: return true
        default: return false
        }
    }

    /// Partially length prefixed body. Returns nil for NULL.
    public static func readPLP(from buffer: inout ByteBuffer) throws -> [UInt8]? {
        guard let total: UInt64 = buffer.readInteger(endianness: .little) else {
            throw TDSNeedMoreData()
        }
        if total == 0xFFFF_FFFF_FFFF_FFFF { return nil } // PLP_NULL
        var out = [UInt8]()
        if total != 0xFFFF_FFFF_FFFF_FFFE, total < 64 * 1024 * 1024 {
            out.reserveCapacity(Int(total))
        }
        while true {
            guard let chunkLen: UInt32 = buffer.readInteger(endianness: .little) else {
                throw TDSNeedMoreData()
            }
            if chunkLen == 0 { break }
            guard let chunk = buffer.readBytes(length: Int(chunkLen)) else {
                throw TDSNeedMoreData()
            }
            out.append(contentsOf: chunk)
        }
        return out
    }

    private static func readVariant(from buffer: inout ByteBuffer) throws -> TDSValue {
        guard let total: Int32 = buffer.readInteger(endianness: .little) else {
            throw TDSNeedMoreData()
        }
        if total == 0 { return .null }
        guard let baseTypeRaw: UInt8 = buffer.readInteger(),
              let propBytes: UInt8 = buffer.readInteger() else {
            throw TDSNeedMoreData()
        }
        guard let baseType = TDSDataType(rawValue: baseTypeRaw) else {
            throw TDSError.protocolError(String(format: "unknown sql_variant base type 0x%02X", baseTypeRaw))
        }

        var info = TDSTypeInfo(dataType: baseType)
        var props = buffer.readSlice(length: Int(propBytes)) ?? ByteBuffer()

        if baseType.hasPrecisionScale {
            info.precision = props.readInteger() ?? 18
            info.scale = props.readInteger() ?? 0
        } else if baseType.hasScaleOnly {
            info.scale = props.readInteger() ?? 7
        }
        if baseType.hasCollation {
            info.collation = props.readCollation()
        }
        if case .ushortLen = baseType.lengthKind {
            if let maxLen: UInt16 = props.readInteger(endianness: .little) { info.length = Int(maxLen) }
        }

        let valueLength = Int(total) - 2 - Int(propBytes)
        guard valueLength >= 0, let bytes = buffer.readBytes(length: valueLength) else {
            throw TDSNeedMoreData()
        }
        if case .fixed(let n) = baseType.lengthKind, n != valueLength {
            info.length = valueLength
        }
        return decodeBytes(bytes, info: info)
    }

    // MARK: - Raw byte decoding

    public static func decodeBytes(_ bytes: [UInt8], info: TDSTypeInfo) -> TDSValue {
        let type = info.dataType

        switch type {
        case .null:
            return .null

        case .bit, .bitN:
            return .bool((bytes.first ?? 0) != 0)

        case .tinyInt:
            return .int(Int64(bytes.first ?? 0))

        case .smallInt:
            return .int(Int64(readInt(bytes, signed: true)))

        case .int, .bigInt:
            return .int(readInt(bytes, signed: true))

        case .intN:
            switch bytes.count {
            case 1: return .int(Int64(bytes[0]))            // tinyint is unsigned
            default: return .int(readInt(bytes, signed: true))
            }

        case .real:
            return .float(Float(bitPattern: UInt32(truncatingIfNeeded: readUInt(bytes))))

        case .float:
            return .double(Double(bitPattern: UInt64(readUInt(bytes))))

        case .floatN:
            if bytes.count == 4 {
                return .float(Float(bitPattern: UInt32(truncatingIfNeeded: readUInt(bytes))))
            }
            return .double(Double(bitPattern: UInt64(readUInt(bytes))))

        case .money:
            guard bytes.count == 8 else { return .null }
            let high = Int64(Int32(truncatingIfNeeded: readUInt(Array(bytes[0..<4]))))
            let low = UInt32(truncatingIfNeeded: readUInt(Array(bytes[4..<8])))
            let combined = (high << 32) | Int64(low)
            return .decimal(TDSDecimal(int64: combined, scale: 4))

        case .smallMoney:
            let v = Int64(Int32(truncatingIfNeeded: readUInt(bytes)))
            return .decimal(TDSDecimal(int64: v, scale: 4))

        case .moneyN:
            if bytes.count == 4 {
                let v = Int64(Int32(truncatingIfNeeded: readUInt(bytes)))
                return .decimal(TDSDecimal(int64: v, scale: 4))
            }
            guard bytes.count == 8 else { return .null }
            let high = Int64(Int32(truncatingIfNeeded: readUInt(Array(bytes[0..<4]))))
            let low = UInt32(truncatingIfNeeded: readUInt(Array(bytes[4..<8])))
            return .decimal(TDSDecimal(int64: (high << 32) | Int64(low), scale: 4))

        case .decimalN, .numericN, .decimalLegacy, .numericLegacy:
            guard let sign = bytes.first else { return .null }
            let magnitude = Array(bytes.dropFirst())
            let digits = decimalString(fromLittleEndianMagnitude: magnitude)
            return .decimal(TDSDecimal(digits: digits, scale: Int(info.scale), isNegative: sign == 0))

        case .uniqueIdentifier:
            guard bytes.count == 16 else { return .null }
            let uuid = UUID(uuid: (
                bytes[3], bytes[2], bytes[1], bytes[0],
                bytes[5], bytes[4],
                bytes[7], bytes[6],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
            return .uuid(uuid)

        case .dateTime:
            return .temporal(decodeDateTime(bytes))

        case .smallDateTime:
            return .temporal(decodeSmallDateTime(bytes))

        case .dateTimeN:
            if bytes.count == 4 { return .temporal(decodeSmallDateTime(bytes)) }
            return .temporal(decodeDateTime(bytes))

        case .dateN:
            return .temporal(decodeDate(bytes))

        case .timeN:
            return .temporal(decodeTime(bytes, scale: Int(info.scale)))

        case .dateTime2N:
            return .temporal(decodeDateTime2(bytes, scale: Int(info.scale)))

        case .dateTimeOffsetN:
            return .temporal(decodeDateTimeOffset(bytes, scale: Int(info.scale)))

        case .bigVarBinary, .bigBinary, .image, .binaryLegacy, .varBinaryLegacy, .udt:
            return .binary(bytes)

        case .xml:
            return .xml(ByteBuffer.decodeUTF16LE(bytes))

        case .nVarChar, .nChar, .nText:
            return .string(ByteBuffer.decodeUTF16LE(bytes))

        case .bigVarChar, .bigChar, .text, .charLegacy, .varCharLegacy:
            return .string(TDSEncodings.decode(bytes, codePage: info.codePage))

        case .sqlVariant:
            return .binary(bytes)
        }
    }

    // MARK: - Helpers

    static func readUInt(_ bytes: [UInt8]) -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in bytes.prefix(8).enumerated() { v |= UInt64(b) << (8 * i) }
        return v
    }

    static func readInt(_ bytes: [UInt8], signed: Bool) -> Int64 {
        let raw = readUInt(bytes)
        guard signed, let last = bytes.last, last & 0x80 != 0, bytes.count < 8 else {
            return Int64(bitPattern: raw)
        }
        // sign extend
        let shift = UInt64(64 - bytes.count * 8)
        return Int64(bitPattern: (raw << shift)) >> Int64(shift)
    }

    /// Convert an arbitrary length little-endian magnitude to a base-10 digit string.
    public static func decimalString(fromLittleEndianMagnitude bytes: [UInt8]) -> String {
        var digits: [UInt8] = [0]
        for byte in bytes.reversed() {
            var carry = Int(byte)
            for i in 0..<digits.count {
                let v = Int(digits[i]) * 256 + carry
                digits[i] = UInt8(v % 10)
                carry = v / 10
            }
            while carry > 0 {
                digits.append(UInt8(carry % 10))
                carry /= 10
            }
        }
        while digits.count > 1 && digits.last == 0 { digits.removeLast() }
        return String(digits.reversed().map { Character(UnicodeScalar(48 + $0)) })
    }

    static func decodeDate(_ bytes: [UInt8]) -> TDSTemporal {
        var t = TDSTemporal(kind: .date)
        let days = Int(readUInt(bytes))
        let civil = TDSCalendar.civilFromDays(days - TDSCalendar.daysFromYearOneToEpoch)
        t.year = civil.year; t.month = civil.month; t.day = civil.day
        t.scale = 0
        return t
    }

    static func decodeTime(_ bytes: [UInt8], scale: Int) -> TDSTemporal {
        var t = TDSTemporal(kind: .time)
        t.scale = scale
        let ticks = readUInt(bytes)
        let divisor = pow10(scale)
        let totalSeconds = ticks / divisor
        let fraction = ticks % divisor
        t.hour = Int(totalSeconds / 3600)
        t.minute = Int((totalSeconds % 3600) / 60)
        t.second = Int(totalSeconds % 60)
        t.nanosecond = Int(fraction * (1_000_000_000 / divisor))
        return t
    }

    static func decodeDateTime2(_ bytes: [UInt8], scale: Int) -> TDSTemporal {
        let timeLength = bytes.count - 3
        guard timeLength > 0 else { return TDSTemporal(kind: .dateTime2) }
        var t = decodeTime(Array(bytes[0..<timeLength]), scale: scale)
        t.kind = .dateTime2
        let days = Int(readUInt(Array(bytes[timeLength...])))
        let civil = TDSCalendar.civilFromDays(days - TDSCalendar.daysFromYearOneToEpoch)
        t.year = civil.year; t.month = civil.month; t.day = civil.day
        return t
    }

    static func decodeDateTimeOffset(_ bytes: [UInt8], scale: Int) -> TDSTemporal {
        guard bytes.count >= 5 else { return TDSTemporal(kind: .dateTimeOffset) }
        let body = Array(bytes[0..<(bytes.count - 2)])
        var t = decodeDateTime2(body, scale: scale)
        t.kind = .dateTimeOffset
        let offsetRaw = Int16(bitPattern: UInt16(truncatingIfNeeded: readUInt(Array(bytes.suffix(2)))))
        t.offsetMinutes = Int(offsetRaw)
        // The stored value is UTC; SQL Server renders it shifted into the offset.
        applyOffset(&t)
        return t
    }

    private static func applyOffset(_ t: inout TDSTemporal) {
        guard t.offsetMinutes != 0 else { return }
        var totalMinutes = t.hour * 60 + t.minute + t.offsetMinutes
        var dayShift = 0
        while totalMinutes < 0 { totalMinutes += 1440; dayShift -= 1 }
        while totalMinutes >= 1440 { totalMinutes -= 1440; dayShift += 1 }
        t.hour = totalMinutes / 60
        t.minute = totalMinutes % 60
        if dayShift != 0 {
            let days = TDSCalendar.daysFromCivil(year: t.year, month: t.month, day: t.day) + dayShift
            let civil = TDSCalendar.civilFromDays(days)
            t.year = civil.year; t.month = civil.month; t.day = civil.day
        }
    }

    static func decodeDateTime(_ bytes: [UInt8]) -> TDSTemporal {
        var t = TDSTemporal(kind: .dateTime)
        t.scale = 3
        guard bytes.count == 8 else { return t }
        let days = Int(Int32(truncatingIfNeeded: readUInt(Array(bytes[0..<4]))))
        let ticks = UInt32(truncatingIfNeeded: readUInt(Array(bytes[4..<8])))
        let civil = TDSCalendar.civilFromDays(days - TDSCalendar.daysFrom1900ToEpoch)
        t.year = civil.year; t.month = civil.month; t.day = civil.day
        // 1/300 second ticks
        let totalMs = (UInt64(ticks) * 1000 + 150) / 300
        t.hour = Int(totalMs / 3_600_000)
        t.minute = Int((totalMs % 3_600_000) / 60_000)
        t.second = Int((totalMs % 60_000) / 1000)
        t.nanosecond = Int((totalMs % 1000) * 1_000_000)
        return t
    }

    static func decodeSmallDateTime(_ bytes: [UInt8]) -> TDSTemporal {
        var t = TDSTemporal(kind: .smallDateTime)
        t.scale = 0
        guard bytes.count == 4 else { return t }
        let days = Int(UInt16(truncatingIfNeeded: readUInt(Array(bytes[0..<2]))))
        let minutes = Int(UInt16(truncatingIfNeeded: readUInt(Array(bytes[2..<4]))))
        let civil = TDSCalendar.civilFromDays(days - TDSCalendar.daysFrom1900ToEpoch)
        t.year = civil.year; t.month = civil.month; t.day = civil.day
        t.hour = minutes / 60
        t.minute = minutes % 60
        return t
    }

    static func pow10(_ n: Int) -> UInt64 {
        var v: UInt64 = 1
        for _ in 0..<max(0, n) { v *= 10 }
        return v
    }
}
