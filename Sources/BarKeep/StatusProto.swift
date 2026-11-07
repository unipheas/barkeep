import Foundation

/// Bounded decoder for the scalar/message types used by BUSY Bar's status schema.
/// Unknown fields are skipped, so additive firmware changes remain compatible.
enum StatusProto {
    struct Field: Decodable {
        let type: String
        let id: Int
        let rule: String?
    }
    struct TypeInfo: Decodable {
        let fields: [String: Field]?
        let values: [String: Int]?
    }
    static func decode(_ data: Data, type: String = "BSB_State.State", depth: Int = 0) throws -> [String: Any] {
        guard data.count <= 1_048_576, depth < 16,
              let fields = StatusSchema.types[type]?.fields else { throw invalid() }
        var reader = Reader(bytes: Array(data))
        var result: [String: Any] = [:]
        while !reader.atEnd {
            let tag = try reader.varint()
            guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw invalid() }
            let wire = Int(tag & 7)
            let field = fields.first { $0.value.id == Int(tag >> 3) }
            let raw: Any
            switch wire {
            case 0: raw = try reader.varint()
            case 1: raw = try reader.fixed(8)
            case 2:
                let count = try reader.varint()
                guard count <= 1_048_576 else { throw invalid() }
                raw = try reader.take(Int(count))
            case 5: raw = try reader.fixed(4)
            default: throw invalid()
            }
            guard let (name, field) = field else { continue }
            let value: Any
            switch field.type {
            case "string":
                guard wire == 2, let bytes = raw as? Data, let string = String(data:bytes,encoding:.utf8) else { throw invalid() }
                value = string
            case "bytes":
                guard wire == 2, let bytes = raw as? Data else { throw invalid() }
                value = bytes.base64EncodedString()
            case "bool", "uint32", "sint32":
                guard wire == 0, let number = raw as? UInt64, number <= UInt32.max else { throw invalid() }
                if field.type == "bool" { value = number != 0 }
                else if field.type == "sint32" { value = Int64(number >> 1) ^ -Int64(number & 1) }
                else { value = number }
            case "fixed64":
                guard wire == 1, let number = raw as? UInt64 else { throw invalid() }
                value = number
            default:
                let resolved = try resolve(field.type, within: type)
                if let values = StatusSchema.types[resolved]?.values {
                    guard wire == 0, let number = raw as? UInt64, number <= UInt32.max else { throw invalid() }
                    value = values.first { $0.value == Int(number) }?.key ?? String(number)
                } else {
                    guard wire == 2, let bytes = raw as? Data else { throw invalid() }
                    value = try decode(bytes,type:resolved,depth:depth+1)
                }
            }
            if field.rule == "repeated" {
                var list = result[name] as? [Any] ?? []
                list.append(value); result[name] = list
            } else { result[name] = value }
        }
        return result
    }

    static func resolve(_ name: String, within type: String) throws -> String {
        if StatusSchema.types[name] != nil { return name }
        var scope = type.split(separator:".").map(String.init)
        while !scope.isEmpty {
            let path = (scope + [name]).joined(separator:".")
            if StatusSchema.types[path] != nil { return path }
            scope.removeLast()
        }
        throw invalid()
    }
    private static func invalid() -> BusyBarError {
        BusyBarError(message:"The bar sent an invalid or unsupported status packet.")
    }
    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var atEnd: Bool { index == bytes.count }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - index else { throw invalid() }
            defer { index += count }
            return Data(bytes[index..<index+count])
        }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift = 0
            while true {
                guard index < bytes.count else { throw invalid() }
                let byte = bytes[index]; index += 1
                if shift == 63 && byte > 1 { throw invalid() }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }
        mutating func fixed(_ count: Int) throws -> UInt64 {
            let data = try take(count)
            return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }
    }
}
