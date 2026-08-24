import Foundation
import NIOCore

/// Fully describes one column's type as sent in COLMETADATA.
public struct TDSTypeInfo: Sendable, Hashable {
    public var dataType: TDSDataType
    /// Maximum length in *bytes* as reported by the server (‑1 when MAX).
    public var length: Int
    public var precision: UInt8
    public var scale: UInt8
    public var collation: TDSCollation?
    public var isMax: Bool
    public var udtDatabase: String?
    public var udtSchema: String?
    public var udtTypeName: String?
    public var udtAssemblyQualifiedName: String?
    public var xmlDatabase: String?
    public var xmlSchema: String?
    public var xmlCollection: String?

    public init(dataType: TDSDataType, length: Int = 0, precision: UInt8 = 0, scale: UInt8 = 0,
                collation: TDSCollation? = nil, isMax: Bool = false) {
        self.dataType = dataType
        self.length = length
        self.precision = precision
        self.scale = scale
        self.collation = collation
        self.isMax = isMax
    }

    /// True when values arrive partially length prefixed.
    public var usesPLP: Bool {
        if isMax { return true }
        switch dataType {
        case .xml, .udt: return true
        default: return false
        }
    }

    public var codePage: UInt32 {
        if dataType.isUnicodeText { return 1200 }
        if let c = collation, !c.isEmpty { return c.codePage }
        return 1252
    }

    /// Character capacity for text types (SQL Server counts characters, TDS counts bytes).
    public var characterLength: Int {
        if isMax { return -1 }
        return dataType.isUnicodeText ? length / 2 : length
    }

    /// The T-SQL type name SSMS would show, e.g. `nvarchar(50)` / `decimal(18,2)`.
    public var sqlTypeName: String {
        func lengthSuffix() -> String {
            if isMax { return "(max)" }
            let n = characterLength
            return n >= 0 ? "(\(n))" : ""
        }
        switch dataType {
        case .null: return "null"
        case .bit, .bitN: return "bit"
        case .tinyInt: return "tinyint"
        case .smallInt: return "smallint"
        case .int: return "int"
        case .bigInt: return "bigint"
        case .intN:
            switch length {
            case 1: return "tinyint"
            case 2: return "smallint"
            case 4: return "int"
            case 8: return "bigint"
            default: return "int"
            }
        case .real: return "real"
        case .float: return "float"
        case .floatN: return length == 4 ? "real" : "float"
        case .money: return "money"
        case .smallMoney: return "smallmoney"
        case .moneyN: return length == 4 ? "smallmoney" : "money"
        case .dateTime: return "datetime"
        case .smallDateTime: return "smalldatetime"
        case .dateTimeN: return length == 4 ? "smalldatetime" : "datetime"
        case .dateN: return "date"
        case .timeN: return "time(\(scale))"
        case .dateTime2N: return "datetime2(\(scale))"
        case .dateTimeOffsetN: return "datetimeoffset(\(scale))"
        case .decimalN, .decimalLegacy: return "decimal(\(precision),\(scale))"
        case .numericN, .numericLegacy: return "numeric(\(precision),\(scale))"
        case .uniqueIdentifier: return "uniqueidentifier"
        case .bigVarChar, .varCharLegacy: return "varchar" + lengthSuffix()
        case .bigChar, .charLegacy: return "char" + lengthSuffix()
        case .nVarChar: return "nvarchar" + lengthSuffix()
        case .nChar: return "nchar" + lengthSuffix()
        case .bigVarBinary, .varBinaryLegacy: return "varbinary" + lengthSuffix()
        case .bigBinary, .binaryLegacy: return "binary" + lengthSuffix()
        case .text: return "text"
        case .nText: return "ntext"
        case .image: return "image"
        case .xml: return "xml"
        case .udt:
            if let n = udtTypeName { return n }
            return "udt"
        case .sqlVariant: return "sql_variant"
        }
    }

    /// Parse a TYPE_INFO structure from the current reader position.
    public static func parse(from buffer: inout ByteBuffer) throws -> TDSTypeInfo {
        guard let rawType: UInt8 = buffer.readInteger() else {
            throw TDSNeedMoreData()
        }
        guard let dataType = TDSDataType(rawValue: rawType) else {
            throw TDSError.protocolError(String(format: "unknown TDS data type 0x%02X", rawType))
        }

        var info = TDSTypeInfo(dataType: dataType)

        switch dataType.lengthKind {
        case .zero:
            info.length = 0

        case .fixed(let n):
            info.length = n

        case .byteLen:
            if dataType == .dateN {
                info.length = 3
            } else if dataType.hasScaleOnly {
                guard let scale: UInt8 = buffer.readInteger() else {
                    throw TDSNeedMoreData()
                }
                info.scale = scale
                info.length = TDSTypeInfo.temporalLength(for: dataType, scale: Int(scale))
            } else {
                guard let len: UInt8 = buffer.readInteger() else {
                    throw TDSNeedMoreData()
                }
                info.length = Int(len)
                if dataType.hasPrecisionScale {
                    guard let precision: UInt8 = buffer.readInteger(),
                          let scale: UInt8 = buffer.readInteger() else {
                        throw TDSNeedMoreData()
                    }
                    info.precision = precision
                    info.scale = scale
                }
                if dataType.hasCollation {
                    guard let collation = buffer.readCollation() else {
                        throw TDSNeedMoreData()
                    }
                    info.collation = collation
                }
            }

        case .ushortLen:
            guard let len: UInt16 = buffer.readInteger(endianness: .little) else {
                throw TDSNeedMoreData()
            }
            if len == 0xFFFF {
                info.isMax = true
                info.length = -1
            } else {
                info.length = Int(len)
            }
            if dataType.hasCollation {
                guard let collation = buffer.readCollation() else {
                    throw TDSNeedMoreData()
                }
                info.collation = collation
            }

        case .longLen:
            guard let len: Int32 = buffer.readInteger(endianness: .little) else {
                throw TDSNeedMoreData()
            }
            info.length = Int(len)
            if dataType.hasCollation {
                guard let collation = buffer.readCollation() else {
                    throw TDSNeedMoreData()
                }
                info.collation = collation
            }

        case .plpOnly:
            if dataType == .xml {
                guard let schemaPresent: UInt8 = buffer.readInteger() else {
                    throw TDSNeedMoreData()
                }
                if schemaPresent == 1 {
                    info.xmlDatabase = buffer.readBVarchar()
                    info.xmlSchema = buffer.readBVarchar()
                    info.xmlCollection = buffer.readUSVarchar()
                }
                info.isMax = true
                info.length = -1
            } else { // udt
                guard let maxLen: UInt16 = buffer.readInteger(endianness: .little) else {
                    throw TDSNeedMoreData()
                }
                info.length = maxLen == 0xFFFF ? -1 : Int(maxLen)
                info.isMax = true
                info.udtDatabase = buffer.readBVarchar()
                info.udtSchema = buffer.readBVarchar()
                info.udtTypeName = buffer.readBVarchar()
                info.udtAssemblyQualifiedName = buffer.readUSVarchar()
            }

        case .variantLen:
            guard let len: Int32 = buffer.readInteger(endianness: .little) else {
                throw TDSNeedMoreData()
            }
            info.length = Int(len)
        }

        return info
    }

    static func temporalLength(for type: TDSDataType, scale: Int) -> Int {
        let timeBytes: Int
        switch scale {
        case 0, 1, 2: timeBytes = 3
        case 3, 4: timeBytes = 4
        default: timeBytes = 5
        }
        switch type {
        case .timeN: return timeBytes
        case .dateTime2N: return timeBytes + 3
        case .dateTimeOffsetN: return timeBytes + 5
        default: return timeBytes
        }
    }
}
