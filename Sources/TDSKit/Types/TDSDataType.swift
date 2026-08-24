import Foundation

/// TDS type tokens (MS-TDS 2.2.5.4/2.2.5.5).
public enum TDSDataType: UInt8, Sendable, Hashable {
    // Fixed length
    case null = 0x1F
    case tinyInt = 0x30
    case bit = 0x32
    case smallInt = 0x34
    case int = 0x38
    case smallDateTime = 0x3A
    case real = 0x3B
    case money = 0x3C
    case dateTime = 0x3D
    case float = 0x3E
    case smallMoney = 0x7A
    case bigInt = 0x7F

    // Variable length, single byte length prefix
    case uniqueIdentifier = 0x24
    case intN = 0x26
    case decimalLegacy = 0x37
    case numericLegacy = 0x3F
    case bitN = 0x68
    case decimalN = 0x6A
    case numericN = 0x6C
    case floatN = 0x6D
    case moneyN = 0x6E
    case dateTimeN = 0x6F
    case charLegacy = 0x2F
    case varCharLegacy = 0x27
    case binaryLegacy = 0x2D
    case varBinaryLegacy = 0x25

    // Date/time family (TDS 7.3+)
    case dateN = 0x28
    case timeN = 0x29
    case dateTime2N = 0x2A
    case dateTimeOffsetN = 0x2B

    // Variable length, two byte length prefix
    case bigVarBinary = 0xA5
    case bigVarChar = 0xA7
    case bigBinary = 0xAD
    case bigChar = 0xAF
    case nVarChar = 0xE7
    case nChar = 0xEF

    // Long / partially length prefixed
    case xml = 0xF1
    case udt = 0xF0
    case text = 0x23
    case image = 0x22
    case nText = 0x63
    case sqlVariant = 0x62

    /// Length category, which determines how TYPE_INFO and values are framed.
    public enum LengthKind: Sendable {
        case zero            // NULLTYPE
        case fixed(Int)      // no length prefix at all
        case byteLen         // BYTE length prefix
        case ushortLen       // USHORT length prefix (0xFFFF == NULL)
        case longLen         // LONG length prefix with text pointer
        case plpOnly         // always partially length prefixed (xml, udt)
        case variantLen      // sql_variant: LONG total length
    }

    public var lengthKind: LengthKind {
        switch self {
        case .null: return .zero
        case .tinyInt, .bit: return .fixed(1)
        case .smallInt: return .fixed(2)
        case .int, .smallDateTime, .real, .smallMoney: return .fixed(4)
        case .money, .dateTime, .float, .bigInt: return .fixed(8)
        case .uniqueIdentifier, .intN, .bitN, .floatN, .moneyN, .dateTimeN,
             .decimalLegacy, .numericLegacy, .decimalN, .numericN,
             .charLegacy, .varCharLegacy, .binaryLegacy, .varBinaryLegacy,
             .dateN, .timeN, .dateTime2N, .dateTimeOffsetN:
            return .byteLen
        case .bigVarBinary, .bigVarChar, .bigBinary, .bigChar, .nVarChar, .nChar:
            return .ushortLen
        case .text, .image, .nText:
            return .longLen
        case .xml, .udt:
            return .plpOnly
        case .sqlVariant:
            return .variantLen
        }
    }

    /// Types whose TYPE_INFO carries a 5 byte COLLATION.
    public var hasCollation: Bool {
        switch self {
        case .bigVarChar, .bigChar, .nVarChar, .nChar, .text, .nText,
             .charLegacy, .varCharLegacy:
            return true
        default:
            return false
        }
    }

    /// Types whose TYPE_INFO carries precision + scale.
    public var hasPrecisionScale: Bool {
        switch self {
        case .decimalN, .numericN, .decimalLegacy, .numericLegacy: return true
        default: return false
        }
    }

    /// Types whose TYPE_INFO carries a single scale byte.
    public var hasScaleOnly: Bool {
        switch self {
        case .timeN, .dateTime2N, .dateTimeOffsetN: return true
        default: return false
        }
    }

    public var isUnicodeText: Bool {
        switch self {
        case .nVarChar, .nChar, .nText, .xml: return true
        default: return false
        }
    }

    public var isBinary: Bool {
        switch self {
        case .bigVarBinary, .bigBinary, .image, .binaryLegacy, .varBinaryLegacy, .udt: return true
        default: return false
        }
    }

    public var isText: Bool {
        switch self {
        case .bigVarChar, .bigChar, .nVarChar, .nChar, .text, .nText, .xml,
             .charLegacy, .varCharLegacy:
            return true
        default:
            return false
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .tinyInt, .smallInt, .int, .bigInt, .intN, .real, .float, .floatN,
             .money, .smallMoney, .moneyN, .decimalN, .numericN, .decimalLegacy, .numericLegacy:
            return true
        default:
            return false
        }
    }

    public var isTemporal: Bool {
        switch self {
        case .dateTime, .smallDateTime, .dateTimeN, .dateN, .timeN, .dateTime2N, .dateTimeOffsetN:
            return true
        default:
            return false
        }
    }
}
