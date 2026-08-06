import Foundation

/// A minimal JSON value used for tool parameter schemas (sent to the model) and
/// for the arguments the model sends back in a tool call. `Codable` so schemas
/// encode into requests and arguments decode from `tool_calls`.
enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before Double: JSONDecoder does not coerce `1` to `true`, and
        // decoding `true` as Double throws, so this order is unambiguous.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    var intValue: Int? { doubleValue.map(Int.init) }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    /// Read a member of an object value, e.g. `arguments["url"]`.
    subscript(_ key: String) -> JSONValue? { objectValue?[key] }
}
