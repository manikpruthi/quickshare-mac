import Foundation

enum ProtoCompatWriter {
    static func varint(_ v: UInt64) -> Data {
        var x = v
        var d = Data()
        while x >= 0x80 {
            d.append(UInt8(x & 0x7f | 0x80))
            x >>= 7
        }
        d.append(UInt8(x))
        return d
    }
}

enum ProtoCompatReader {
    static func readVarint(_ data: Data, _ pos: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift = 0
        while pos < data.count {
            let byte = data[pos]
            pos += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtoCompatError.truncated }
        }
        throw ProtoCompatError.truncated
    }
}

enum ProtoCompatError: Error {
    case truncated
}
