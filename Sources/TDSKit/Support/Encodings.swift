import Foundation

/// Maps SQL Server collation code pages to Foundation string encodings.
/// This matters a lot for non-Unicode (`char`/`varchar`/`text`) columns:
/// e.g. Persian/Arabic collations use Windows-1256, Cyrillic uses 1251, and
/// modern UTF-8 collations use 65001.
public enum TDSEncodings {

    /// Resolve a Windows code page number to a Foundation `String.Encoding`.
    public static func encoding(forCodePage codePage: UInt32) -> String.Encoding {
        switch codePage {
        case 65001: return .utf8
        case 1200: return .utf16LittleEndian
        case 1201: return .utf16BigEndian
        case 20127: return .ascii
        default:
            let cfEnc = CFStringConvertWindowsCodepageToEncoding(codePage)
            if cfEnc != kCFStringEncodingInvalidId {
                let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
                if nsEnc != UInt(kCFStringEncodingInvalidId) {
                    return String.Encoding(rawValue: nsEnc)
                }
            }
            return .windowsCP1252
        }
    }

    /// Decode bytes using a code page, falling back progressively so we never lose data.
    public static func decode(_ bytes: [UInt8], codePage: UInt32) -> String {
        let data = Data(bytes)
        let enc = encoding(forCodePage: codePage)
        if let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func encode(_ string: String, codePage: UInt32) -> [UInt8] {
        let enc = encoding(forCodePage: codePage)
        if let d = string.data(using: enc, allowLossyConversion: true) { return [UInt8](d) }
        return [UInt8](string.utf8)
    }
}

/// The 5 byte COLLATION structure that follows character types in COLMETADATA.
public struct TDSCollation: Sendable, Hashable, Codable {
    /// LCID + flags packed in the first 4 bytes.
    public var raw: UInt32
    public var sortId: UInt8

    public init(raw: UInt32, sortId: UInt8) {
        self.raw = raw
        self.sortId = sortId
    }

    public var lcid: UInt32 { raw & 0x000F_FFFF }

    public var isEmpty: Bool { raw == 0 && sortId == 0 }

    /// Windows code page implied by the collation's LCID / sort id.
    public var codePage: UInt32 {
        if sortId != 0, let cp = TDSCollation.sortIdCodePages[sortId] { return cp }
        return TDSCollation.codePage(forLCID: lcid)
    }

    /// Non-exhaustive but covers every code page SQL Server can actually store.
    public static func codePage(forLCID lcid: UInt32) -> UInt32 {
        let primary = lcid & 0x3FF
        switch primary {
        case 0x01: return 1256 // Arabic
        case 0x02: return 1251 // Bulgarian
        case 0x03: return 1252 // Catalan
        case 0x04: return 950  // Chinese (Traditional)
        case 0x05: return 1250 // Czech
        case 0x06: return 1252 // Danish
        case 0x07: return 1252 // German
        case 0x08: return 1253 // Greek
        case 0x09: return 1252 // English
        case 0x0A: return 1252 // Spanish
        case 0x0B: return 1252 // Finnish
        case 0x0C: return 1252 // French
        case 0x0D: return 1255 // Hebrew
        case 0x0E: return 1250 // Hungarian
        case 0x0F: return 1252 // Icelandic
        case 0x10: return 1252 // Italian
        case 0x11: return 932  // Japanese
        case 0x12: return 949  // Korean
        case 0x13: return 1252 // Dutch
        case 0x14: return 1252 // Norwegian
        case 0x15: return 1250 // Polish
        case 0x16: return 1252 // Portuguese
        case 0x18: return 1250 // Romanian
        case 0x19: return 1251 // Russian
        case 0x1A: return 1250 // Croatian/Serbian (Latin)
        case 0x1B: return 1250 // Slovak
        case 0x1C: return 1250 // Albanian
        case 0x1D: return 1252 // Swedish
        case 0x1E: return 874  // Thai
        case 0x1F: return 1254 // Turkish
        case 0x20: return 1256 // Urdu
        case 0x21: return 1252 // Indonesian
        case 0x22: return 1251 // Ukrainian
        case 0x23: return 1251 // Belarusian
        case 0x24: return 1250 // Slovenian
        case 0x25: return 1257 // Estonian
        case 0x26: return 1257 // Latvian
        case 0x27: return 1257 // Lithuanian
        case 0x29: return 1256 // Persian (Farsi)
        case 0x2A: return 1258 // Vietnamese
        case 0x2C: return 1254 // Azeri (Latin)
        case 0x2D: return 1252 // Basque
        case 0x2F: return 1251 // Macedonian
        case 0x36: return 1252 // Afrikaans
        case 0x37: return 1252 // Georgian
        case 0x38: return 1252 // Faroese
        case 0x39: return 1256 // Hindi -> unicode only
        case 0x3E: return 1252 // Malay
        case 0x3F: return 1251 // Kazakh
        case 0x40: return 1251 // Kyrgyz
        case 0x41: return 1252 // Swahili
        case 0x43: return 1254 // Uzbek (Latin)
        case 0x44: return 1251 // Tatar
        case 0x4E: return 1252 // Marathi
        case 0x56: return 1252 // Galician
        case 0x04_00: return 1252
        default: return 1252
        }
    }

    /// Legacy SQL sort orders that pin a code page directly.
    static let sortIdCodePages: [UInt8: UInt32] = [
        30: 437, 31: 437, 32: 437, 33: 437, 34: 437,
        40: 850, 41: 850, 42: 850, 43: 850, 44: 850, 49: 850,
        50: 1252, 51: 1252, 52: 1252, 53: 1252, 54: 1252,
        55: 850, 56: 850, 57: 850, 58: 850, 59: 850, 60: 850, 61: 850,
        71: 1252, 72: 1252, 73: 1252, 74: 1252,
        80: 1250, 81: 1250, 82: 1250, 83: 1250, 84: 1250, 85: 1250, 86: 1250,
        87: 1250, 88: 1250, 89: 1250, 90: 1250, 91: 1250, 92: 1250, 93: 1250,
        94: 1250, 95: 1250, 96: 1250,
        104: 1251, 105: 1251, 106: 1251, 107: 1251, 108: 1251,
        112: 1253, 113: 1253, 114: 1253, 120: 1253, 121: 1253, 124: 1253,
        128: 1254, 129: 1254, 130: 1254,
        136: 1255, 137: 1255, 138: 1255,
        144: 1256, 145: 1256, 146: 1256,
        152: 1257, 153: 1257, 154: 1257, 155: 1257, 156: 1257,
        157: 1257, 158: 1257, 159: 1257, 160: 1257,
        183: 1252, 184: 1252, 185: 1252, 186: 1252,
        192: 932, 193: 932, 194: 949, 195: 949, 196: 950, 197: 950,
        198: 936, 199: 936, 200: 932, 201: 949, 202: 950, 203: 936,
        204: 874, 205: 874, 206: 874,
        210: 1252, 211: 1252, 212: 1252, 213: 1252, 214: 1252, 215: 1252,
        216: 1252, 217: 1252
    ]
}
