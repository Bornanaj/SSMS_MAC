import Foundation
import TDSKit

/// T-SQL literals that mean the same thing under every `SET LANGUAGE` / `SET DATEFORMAT`.
///
/// `TDSValue.sqlLiteral` is fine for display, but `'2024-03-04 10:00:00.000'` is read as
/// 3 April under `DATEFORMAT dmy` when the target is `datetime`. Deployment scripts run
/// under whatever language the deploying login has, so dates are written in the forms
/// SQL Server documents as language-neutral.
public enum SQLLiteral {

    public static func render(_ value: TDSValue) -> String {
        switch value {
        case .temporal(let temporal):
            return temporalLiteral(temporal)
        case .double(let number) where number.isNaN || number.isInfinite:
            return "NULL"
        case .float(let number) where number.isNaN || number.isInfinite:
            return "NULL"
        default:
            return value.sqlLiteral
        }
    }

    static func temporalLiteral(_ value: TDSTemporal) -> String {
        func pad(_ number: Int, _ width: Int) -> String {
            let text = String(abs(number))
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let date = "\(pad(value.year, 4))-\(pad(value.month, 2))-\(pad(value.day, 2))"
        let time = "\(pad(value.hour, 2)):\(pad(value.minute, 2)):\(pad(value.second, 2))"
        switch value.kind {
        case .date:
            return "'\(pad(value.year, 4))\(pad(value.month, 2))\(pad(value.day, 2))'"
        case .smallDateTime:
            return "'\(date)T\(time)'"
        case .dateTime:
            return "'\(date)T\(time).\(pad(value.nanosecond / 1_000_000, 3))'"
        case .time, .dateTime2, .dateTimeOffset:
            return value.sqlLiteral
        }
    }

    /// Hex text for a binary value, without the `0x` prefix.
    public static func hex(_ bytes: [UInt8]) -> String {
        let digits: [Character] = Array("0123456789ABCDEF")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }
}
