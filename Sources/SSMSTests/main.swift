import Foundation
import NIOCore
import NIOEmbedded
import TDSKit
import SQLServerKit

let t = TestRunner()

// MARK: - Calendar

t.suite("calendar") {
    for (year, month, day) in [(1, 1, 1), (1900, 1, 1), (1970, 1, 1), (2000, 2, 29),
                               (2024, 2, 29), (2026, 12, 31), (9999, 12, 31)] {
        let days = TDSCalendar.daysFromCivil(year: year, month: month, day: day)
        let back = TDSCalendar.civilFromDays(days)
        t.expect(back.year == year && back.month == month && back.day == day,
                 "round trip \(year)-\(month)-\(day)", "got \(back)")
    }
    t.equal(TDSCalendar.daysFromCivil(year: 1970, month: 1, day: 1), 0, "unix epoch is day zero")
    t.equal(TDSCalendar.daysFromCivil(year: 1, month: 1, day: 1),
            -TDSCalendar.daysFromYearOneToEpoch, "year one offset")
    t.equal(TDSCalendar.daysFromCivil(year: 1900, month: 1, day: 1),
            -TDSCalendar.daysFrom1900ToEpoch, "1900 offset")
}

// MARK: - Value decoding

func info(_ type: TDSDataType, length: Int = 0, precision: UInt8 = 0, scale: UInt8 = 0) -> TDSTypeInfo {
    TDSTypeInfo(dataType: type, length: length, precision: precision, scale: scale)
}

func littleEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
}

/// Repeated division by 256 turns a decimal digit string into the little-endian
/// magnitude SQL Server puts on the wire for decimal/numeric.
func littleEndianMagnitude(ofDecimal digits: String) -> [UInt8] {
    var magnitude: [UInt8] = []
    var remaining = digits
    while remaining != "0" {
        var quotient = ""
        var carry = 0
        for character in remaining {
            let digit = Int(String(character)) ?? 0
            let current: Int = carry * 10 + digit
            quotient.append(String(current / 256))
            carry = current % 256
        }
        magnitude.append(UInt8(carry))
        while quotient.count > 1 && quotient.hasPrefix("0") { quotient.removeFirst() }
        remaining = quotient
    }
    return magnitude
}

t.suite("integers") {
    t.equal(TDSValueDecoder.decodeBytes([0xFF], info: info(.tinyInt)), .int(255), "tinyint is unsigned")
    t.equal(TDSValueDecoder.decodeBytes([0x2E, 0xFB], info: info(.smallInt)), .int(-1234),
            "negative smallint sign extends")
    t.equal(TDSValueDecoder.decodeBytes([0xFF, 0xFF, 0xFF, 0x7F], info: info(.int)),
            .int(2147483647), "int max")
    t.equal(TDSValueDecoder.decodeBytes(littleEndian(0x8000_0000_0000_0000, 8), info: info(.bigInt)),
            .int(Int64.min), "bigint min")
}

t.suite("money and decimal") {
    // money stores the high word first.
    let scaled: Int64 = 12_345_678
    let high = UInt32(bitPattern: Int32(truncatingIfNeeded: scaled >> 32))
    let low = UInt32(truncatingIfNeeded: scaled)
    let bytes = littleEndian(UInt64(high), 4) + littleEndian(UInt64(low), 4)
    if case .decimal(let decimal) = TDSValueDecoder.decodeBytes(bytes, info: info(.money)) {
        t.equal(decimal.description, "1234.5678", "money high word first")
    } else {
        t.expect(false, "money decodes to a decimal")
    }

    let negative = TDSDecimal(digits: "12345", scale: 2, isNegative: true)
    t.equal(negative.description, "-123.45", "negative decimal")
    t.equal(TDSDecimal(digits: "5", scale: 4, isNegative: false).description, "0.0005",
            "decimal pads leading zeros")
    t.equal(TDSDecimal(digits: "0", scale: 2, isNegative: true).description, "0.00",
            "negative zero has no sign")

    // 38 digit magnitudes must survive without touching Double.
    let digits = "123456789012345678901234567890000000"
    let magnitude = littleEndianMagnitude(ofDecimal: digits)
    t.equal(TDSValueDecoder.decimalString(fromLittleEndianMagnitude: magnitude), digits,
            "36 digit magnitude round trips")
}

t.suite("temporal") {
    let days = TDSCalendar.daysFromCivil(year: 1999, month: 12, day: 31)
        + TDSCalendar.daysFrom1900ToEpoch
    let secondsOfDay: Int = 23 * 3600 + 59 * 60 + 59
    let ticks = UInt32(secondsOfDay * 300 + 299)
    let bytes = littleEndian(UInt64(UInt32(bitPattern: Int32(days))), 4)
        + littleEndian(UInt64(ticks), 4)
    if case .temporal(let value) = TDSValueDecoder.decodeBytes(bytes, info: info(.dateTime)) {
        t.equal(value.displayString, "1999-12-31 23:59:59.997", "datetime rendering")
    } else {
        t.expect(false, "datetime decodes")
    }

    let dateDays = TDSCalendar.daysFromCivil(year: 2024, month: 2, day: 29)
        + TDSCalendar.daysFromYearOneToEpoch
    if case .temporal(let value) = TDSValueDecoder.decodeBytes(littleEndian(UInt64(dateDays), 3),
                                                              info: info(.dateN)) {
        t.equal(value.displayString, "2024-02-29", "leap day")
    } else {
        t.expect(false, "date decodes")
    }

    // time(7): 13:45:56.1234567
    let scale = 7
    let subseconds: UInt64 = 1_234_567
    let timeSeconds: Int = 13 * 3600 + 45 * 60 + 56
    let timeTicks: UInt64 = UInt64(timeSeconds) * 10_000_000 + subseconds
    if case .temporal(let value) = TDSValueDecoder.decodeBytes(littleEndian(timeTicks, 5),
                                                              info: info(.timeN, scale: UInt8(scale))) {
        t.equal(value.displayString, "13:45:56.1234567", "time(7) rendering")
    } else {
        t.expect(false, "time decodes")
    }
}

t.suite("guid and float") {
    let bytes: [UInt8] = [0x78, 0x56, 0x34, 0x12, 0xBC, 0x9A, 0xF0, 0xDE,
                          0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    if case .uuid(let uuid) = TDSValueDecoder.decodeBytes(bytes, info: info(.uniqueIdentifier)) {
        t.equal(uuid.uuidString, "12345678-9ABC-DEF0-0102-030405060708", "guid byte order")
    } else {
        t.expect(false, "guid decodes")
    }

    let real = Float(3.14159)
    t.equal(TDSValueDecoder.decodeBytes(littleEndian(UInt64(real.bitPattern), 4),
                                        info: info(.real)).displayString(),
            "3.14159", "real keeps 7 significant digits")
}

t.suite("collations") {
    t.equal(TDSCollation.codePage(forLCID: 0x0429), 1256, "Persian is CP1256")
    t.equal(TDSCollation.codePage(forLCID: 0x0401), 1256, "Arabic is CP1256")
    t.equal(TDSCollation.codePage(forLCID: 0x0419), 1251, "Russian is CP1251")
    t.equal(TDSCollation.codePage(forLCID: 0x0409), 1252, "English is CP1252")
    t.equal(TDSCollation.codePage(forLCID: 0x041F), 1254, "Turkish is CP1254")
    t.equal(TDSEncodings.decode([0xD3, 0xE1, 0xC7, 0xE3], codePage: 1256), "سلام",
            "CP1256 bytes decode to Persian text")
}

// MARK: - Protocol

t.suite("protocol") {
    let original: [UInt8] = Array("P@ssw0rd!".utf8)
    let scrambled = Login7Request.obfuscate(original)
    let restored = scrambled.map { byte -> UInt8 in
        let x = byte ^ 0xA5
        return (x >> 4) | (x << 4)
    }
    t.expect(restored == original, "password obfuscation is reversible")
    t.expect(scrambled != original, "password is actually scrambled")

    func hex(_ text: String) -> String {
        MD4.hash(bytes: Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    t.equal(hex(""), "31d6cfe0d16ae931b73c59d7e0c089c0", "MD4 of empty string")
    t.equal(hex("abc"), "a448017aaf21d8525fc10ae87aa6729d", "MD4 of abc")
    t.equal(hex("message digest"), "d9130a8164549fe818874806e1c7014b", "MD4 of message digest")

    var parsed = TDSConfiguration.parseServerName("localhost")
    t.equal(parsed.host, "localhost", "bare host")
    parsed = TDSConfiguration.parseServerName("db.example.com,1433")
    t.expect(parsed.host == "db.example.com" && parsed.port == 1433, "host,port")
    parsed = TDSConfiguration.parseServerName("SERVER\\SQLEXPRESS")
    t.expect(parsed.host == "SERVER" && parsed.instance == "SQLEXPRESS", "named instance")
    parsed = TDSConfiguration.parseServerName("tcp:SERVER\\INST,1434")
    t.expect(parsed.host == "SERVER" && parsed.instance == "INST" && parsed.port == 1434,
             "tcp prefix with instance and port")
    t.equal(TDSConfiguration.parseServerName("(local)").host, "localhost", "(local) alias")
}

t.suite("packet framing") {
    var buffer = ByteBuffer()
    func appendPacket(status: UInt8, payload: [UInt8]) {
        buffer.writeInteger(UInt8(0x04))
        buffer.writeInteger(status)
        buffer.writeInteger(UInt16(payload.count + 8), endianness: .big)
        buffer.writeInteger(UInt16(0), endianness: .big)
        buffer.writeInteger(UInt8(1))
        buffer.writeInteger(UInt8(0))
        buffer.writeBytes(payload)
    }
    appendPacket(status: 0x00, payload: [1, 2, 3])
    appendPacket(status: 0x01, payload: [4, 5])

    let channel = EmbeddedChannel(handler: ByteToMessageHandler(TDSPacketDecoder()))
    do {
        try channel.writeInbound(buffer)
        let first = try channel.readInbound(as: TDSPacket.self)
        t.expect(first?.payload.readableBytes == 3 && first?.isEndOfMessage == false,
                 "first packet is not end of message")
        let second = try channel.readInbound(as: TDSPacket.self)
        t.expect(second?.payload.readableBytes == 2 && second?.isEndOfMessage == true,
                 "second packet ends the message")
        _ = try channel.finish()
    } catch {
        t.expect(false, "packet decoding", "\(error)")
    }
}

exit(runSQLServerKitTests(t, extra: runDiagnosticsTests))
