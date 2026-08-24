import Foundation
import NIOCore

@inline(__always)
private func req<T>(_ value: T?) throws -> T {
    guard let value else { throw TDSNeedMoreData() }
    return value
}

/// Incremental parser for the TDS token stream.
///
/// `parse` consumes as many complete tokens as the buffer holds and rewinds when a
/// token is only partially present, so a result set of any size can be streamed
/// packet by packet without buffering the whole response.
public struct TDSTokenStreamParser {
    public private(set) var columns: [TDSColumn] = []
    /// Column metadata captured for RETURNVALUE parsing of the current RPC.
    public var transactionDescriptor: [UInt8] = []

    public init() {}

    public mutating func reset() {
        columns = []
    }

    public mutating func parse(_ buffer: inout ByteBuffer, emit: (TDSToken) throws -> Void) throws {
        while buffer.readableBytes > 0 {
            let saved = buffer.readerIndex
            do {
                try parseToken(&buffer, emit: emit)
            } catch is TDSNeedMoreData {
                buffer.moveReaderIndex(to: saved)
                return
            }
        }
    }

    private mutating func parseToken(_ buffer: inout ByteBuffer, emit: (TDSToken) throws -> Void) throws {
        let tokenType: UInt8 = try req(buffer.readInteger())

        switch tokenType {
        case 0x81: // COLMETADATA
            let count: UInt16 = try req(buffer.readInteger(endianness: .little))
            if count == 0xFFFF {
                columns = []
                return
            }
            var parsed: [TDSColumn] = []
            parsed.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                parsed.append(try parseColumn(index: i, from: &buffer))
            }
            columns = parsed
            try emit(.columnMetadata(parsed))

        case 0xD1: // ROW
            guard !columns.isEmpty else {
                throw TDSError.protocolError("ROW token received before COLMETADATA")
            }
            var values = [TDSValue]()
            values.reserveCapacity(columns.count)
            for column in columns {
                values.append(try TDSValueDecoder.readValue(type: column.typeInfo, from: &buffer))
            }
            try emit(.row(values))

        case 0xD2: // NBCROW
            guard !columns.isEmpty else {
                throw TDSError.protocolError("NBCROW token received before COLMETADATA")
            }
            let bitmapBytes = (columns.count + 7) / 8
            let bitmap = try req(buffer.readBytes(length: bitmapBytes))
            var values = [TDSValue]()
            values.reserveCapacity(columns.count)
            for column in columns {
                let isNull = (bitmap[column.index / 8] & (1 << UInt8(column.index % 8))) != 0
                if isNull {
                    values.append(.null)
                } else {
                    values.append(try TDSValueDecoder.readValue(type: column.typeInfo, from: &buffer))
                }
            }
            try emit(.row(values))

        case 0xFD, 0xFE, 0xFF: // DONE / DONEPROC / DONEINPROC
            let status: UInt16 = try req(buffer.readInteger(endianness: .little))
            let curCmd: UInt16 = try req(buffer.readInteger(endianness: .little))
            let rowCount: UInt64 = try req(buffer.readInteger(endianness: .little))
            let info = TDSDoneInfo(status: TDSDoneStatus(rawValue: status),
                                   currentCommand: curCmd,
                                   rowCount: Int64(bitPattern: rowCount))
            switch tokenType {
            case 0xFD: try emit(.done(info))
            case 0xFE: try emit(.doneProc(info))
            default: try emit(.doneInProc(info))
            }

        case 0xAA, 0xAB: // ERROR / INFO
            let length: UInt16 = try req(buffer.readInteger(endianness: .little))
            var slice = try req(buffer.readSlice(length: Int(length)))
            let message = try parseMessage(&slice)
            try emit(tokenType == 0xAA ? .error(message) : .info(message))

        case 0xE3: // ENVCHANGE
            let length: UInt16 = try req(buffer.readInteger(endianness: .little))
            var slice = try req(buffer.readSlice(length: Int(length)))
            if let change = parseEnvChange(&slice) {
                try emit(.envChange(change))
            }

        case 0xAD: // LOGINACK
            let length: UInt16 = try req(buffer.readInteger(endianness: .little))
            var slice = try req(buffer.readSlice(length: Int(length)))
            let interfaceType: UInt8 = try req(slice.readInteger())
            let version: UInt32 = try req(slice.readInteger(endianness: .big))
            let progName = slice.readBVarchar() ?? ""
            let major: UInt8 = slice.readInteger() ?? 0
            let minor: UInt8 = slice.readInteger() ?? 0
            let buildHigh: UInt8 = slice.readInteger() ?? 0
            let buildLow: UInt8 = slice.readInteger() ?? 0
            try emit(.loginAck(TDSLoginAck(
                interfaceType: interfaceType,
                tdsVersion: version,
                programName: progName,
                majorVersion: major,
                minorVersion: minor,
                buildNumber: (UInt16(buildHigh) << 8) | UInt16(buildLow)
            )))

        case 0x79: // RETURNSTATUS
            let value: Int32 = try req(buffer.readInteger(endianness: .little))
            try emit(.returnStatus(value))

        case 0xAC: // RETURNVALUE
            let ordinal: UInt16 = try req(buffer.readInteger(endianness: .little))
            let name = try req(buffer.readBVarchar())
            let status: UInt8 = try req(buffer.readInteger())
            let userType: UInt32 = try req(buffer.readInteger(endianness: .little))
            let flags: UInt16 = try req(buffer.readInteger(endianness: .little))
            let typeInfo = try TDSTypeInfo.parse(from: &buffer)
            let value = try TDSValueDecoder.readValue(type: typeInfo, from: &buffer)
            let column = TDSColumn(index: Int(ordinal), name: name, typeInfo: typeInfo,
                                   userType: userType, nullable: flags & 0x01 != 0)
            try emit(.returnValue(TDSReturnValue(ordinal: Int(ordinal), name: name,
                                                 status: status, column: column, value: value)))

        case 0xA9: // ORDER
            let length: UInt16 = try req(buffer.readInteger(endianness: .little))
            var slice = try req(buffer.readSlice(length: Int(length)))
            var order = [Int]()
            while slice.readableBytes >= 2 {
                if let v: UInt16 = slice.readInteger(endianness: .little) { order.append(Int(v)) }
            }
            try emit(.order(order))

        case 0xA5: // COLINFO
            let length: UInt16 = try req(buffer.readInteger(endianness: .little))
            _ = try req(buffer.readSlice(length: Int(length)))

        case 0xA4: // TABNAME
            let length: UInt16 = try req(buffer.readInteger(endianness: .little))
            var slice = try req(buffer.readSlice(length: Int(length)))
            var names = [String]()
            while slice.readableBytes > 0 {
                guard let numParts: UInt8 = slice.readInteger() else { break }
                var parts = [String]()
                for _ in 0..<Int(numParts) {
                    guard let part = slice.readUSVarchar() else { break }
                    parts.append(part)
                }
                names.append(parts.joined(separator: "."))
            }
            try emit(.tableName(names))

        case 0xED: // SSPI
            let payload = try req(buffer.readUSVarbyte())
            try emit(.sspi(payload))

        case 0xEE: // FEDAUTHINFO
            let length: UInt32 = try req(buffer.readInteger(endianness: .little))
            let slice = try req(buffer.readSlice(length: Int(length)))
            var reader = slice
            var stsURL = ""
            var spn = ""
            if let count: UInt32 = reader.readInteger(endianness: .little) {
                // Offsets are measured from the first byte of CountOfInfoIDs.
                var entries: [(id: UInt8, length: Int, offset: Int)] = []
                for _ in 0..<count {
                    guard let id: UInt8 = reader.readInteger(),
                          let dataLen: UInt32 = reader.readInteger(endianness: .little),
                          let offset: UInt32 = reader.readInteger(endianness: .little) else { break }
                    entries.append((id, Int(dataLen), Int(offset)))
                }
                for entry in entries {
                    guard let data = slice.getBytes(at: entry.offset, length: entry.length) else { continue }
                    let text = ByteBuffer.decodeUTF16LE(data)
                    if entry.id == 0x01 { stsURL = text } else if entry.id == 0x02 { spn = text }
                }
            }
            try emit(.fedAuthInfo(stsURL: stsURL, spn: spn))

        case 0xAE: // FEATUREEXTACK
            var acks = [UInt8: [UInt8]]()
            while true {
                let featureID: UInt8 = try req(buffer.readInteger())
                if featureID == 0xFF { break }
                let dataLen: UInt32 = try req(buffer.readInteger(endianness: .little))
                let data = try req(buffer.readBytes(length: Int(dataLen)))
                acks[featureID] = data
            }
            try emit(.featureExtAck(acks))

        case 0xE4: // SESSIONSTATE
            let length: UInt32 = try req(buffer.readInteger(endianness: .little))
            _ = try req(buffer.readSlice(length: Int(length)))
            try emit(.sessionState)

        default:
            throw TDSError.protocolError(String(format: "unexpected token 0x%02X in the response stream", tokenType))
        }
    }

    private func parseColumn(index: Int, from buffer: inout ByteBuffer) throws -> TDSColumn {
        let userType: UInt32 = try req(buffer.readInteger(endianness: .little))
        let flags: UInt16 = try req(buffer.readInteger(endianness: .little))
        let typeInfo = try TDSTypeInfo.parse(from: &buffer)

        var tableName: String?
        switch typeInfo.dataType {
        case .text, .nText, .image:
            let numParts: UInt8 = try req(buffer.readInteger())
            var parts = [String]()
            for _ in 0..<Int(numParts) {
                parts.append(try req(buffer.readUSVarchar()))
            }
            tableName = parts.joined(separator: ".")
        default:
            break
        }

        let name = try req(buffer.readBVarchar())

        return TDSColumn(
            index: index,
            name: name,
            typeInfo: typeInfo,
            userType: userType,
            nullable: flags & 0x0001 != 0,
            caseSensitive: flags & 0x0002 != 0,
            updatable: Int((flags >> 2) & 0x03),
            identity: flags & 0x0010 != 0,
            computed: flags & 0x0020 != 0,
            sparse: flags & 0x0400 != 0,
            encrypted: flags & 0x0800 != 0,
            hidden: flags & 0x2000 != 0,
            tableName: tableName
        )
    }

    private func parseMessage(_ slice: inout ByteBuffer) throws -> TDSServerMessage {
        let number: Int32 = try req(slice.readInteger(endianness: .little))
        let state: UInt8 = try req(slice.readInteger())
        let severity: UInt8 = try req(slice.readInteger())
        let text = try req(slice.readUSVarchar())
        let serverName = slice.readBVarchar() ?? ""
        let procName = slice.readBVarchar() ?? ""
        let line: Int32 = slice.readInteger(endianness: .little) ?? 0
        return TDSServerMessage(number: number, state: state, severity: severity, text: text,
                                serverName: serverName, procedureName: procName, lineNumber: line)
    }

    private func parseEnvChange(_ slice: inout ByteBuffer) -> TDSEnvChange? {
        guard let type: UInt8 = slice.readInteger() else { return nil }
        switch type {
        case 1:
            let new = slice.readBVarchar() ?? ""
            let old = slice.readBVarchar() ?? ""
            return .database(new: new, old: old)
        case 2:
            let new = slice.readBVarchar() ?? ""
            let old = slice.readBVarchar() ?? ""
            return .language(new: new, old: old)
        case 3:
            let new = slice.readBVarchar() ?? ""
            let old = slice.readBVarchar() ?? ""
            return .characterSet(new: new, old: old)
        case 4:
            let new = slice.readBVarchar() ?? ""
            let old = slice.readBVarchar() ?? ""
            return .packetSize(new: Int(new) ?? 4096, old: Int(old) ?? 4096)
        case 7:
            let new = slice.readBVarbyte() ?? []
            let old = slice.readBVarbyte() ?? []
            return .sqlCollation(new: new, old: old)
        case 8:
            return .beginTransaction(slice.readBVarbyte() ?? [])
        case 9:
            return .commitTransaction(slice.readBVarbyte() ?? [])
        case 10:
            return .rollbackTransaction(slice.readBVarbyte() ?? [])
        case 18:
            return .resetConnectionAck
        case 20:
            guard let payload = slice.readUSVarbyte() else { return .other(type: type) }
            var routing = ByteBuffer(bytes: payload)
            guard let protocolByte: UInt8 = routing.readInteger(), protocolByte == 0,
                  let port: UInt16 = routing.readInteger(endianness: .little),
                  let hostLen: UInt16 = routing.readInteger(endianness: .little),
                  let host = routing.readUCS2String(charCount: Int(hostLen)) else {
                return .other(type: type)
            }
            return .routing(host: host, port: Int(port))
        default:
            return .other(type: type)
        }
    }
}
