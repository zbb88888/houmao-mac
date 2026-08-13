import Foundation

/// 引擎线协议用的 CBOR 值（RFC 8949 的最小子集，仅覆盖协议实际用到的类型）。
/// 定长编码；map 键为字符串、有序（编码确定性）。
///
/// 支持：无符号整数 / 文本串 / 数组 / 字符串键 map / bool / null。
/// 不支持：负整数、浮点、字节串、tag、不定长——协议 schema 里都没有。
enum CBORValue: Equatable {
    case uint(UInt64)
    case text(String)
    case array([CBORValue])
    case map([(String, CBORValue)])
    case bool(Bool)
    case null

    static func == (lhs: CBORValue, rhs: CBORValue) -> Bool {
        switch (lhs, rhs) {
        case let (.uint(a), .uint(b)): return a == b
        case let (.text(a), .text(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        case let (.map(a), .map(b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    // MARK: 便捷读取

    var stringValue: String? { if case let .text(s) = self { return s } else { return nil } }
    var uintValue: UInt64? { if case let .uint(n) = self { return n } else { return nil } }
    var boolValue: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    var arrayValue: [CBORValue]? { if case let .array(a) = self { return a } else { return nil } }

    /// map 按键取值（顺序无关）。
    subscript(_ key: String) -> CBORValue? {
        if case let .map(pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }
}

enum CBORError: Error, Equatable {
    case truncated
    case nonStringKey
    case unsupported(UInt8)
    case invalidUTF8
    case trailingData
}

// MARK: - 编码

/// 编码单个 CBOR 值为定长字节。
func encodeCBOR(_ value: CBORValue) -> Data {
    var out = Data()
    appendCBOR(value, into: &out)
    return out
}

private func appendCBOR(_ value: CBORValue, into out: inout Data) {
    switch value {
    case let .uint(n):
        appendHead(major: 0, n, into: &out)
    case let .text(s):
        let bytes = Array(s.utf8)
        appendHead(major: 3, UInt64(bytes.count), into: &out)
        out.append(contentsOf: bytes)
    case let .array(items):
        appendHead(major: 4, UInt64(items.count), into: &out)
        for item in items { appendCBOR(item, into: &out) }
    case let .map(pairs):
        appendHead(major: 5, UInt64(pairs.count), into: &out)
        for (key, val) in pairs {
            appendCBOR(.text(key), into: &out)
            appendCBOR(val, into: &out)
        }
    case let .bool(b):
        out.append(b ? 0xf5 : 0xf4)
    case .null:
        out.append(0xf6)
    }
}

/// 写主类型头 + 最小编码的参数。
private func appendHead(major: UInt8, _ n: UInt64, into out: inout Data) {
    let mt = major << 5
    if n < 24 {
        out.append(mt | UInt8(n))
    } else if n <= UInt64(UInt8.max) {
        out.append(mt | 24)
        out.append(UInt8(n))
    } else if n <= UInt64(UInt16.max) {
        out.append(mt | 25)
        out.append(UInt8(n >> 8))
        out.append(UInt8(n & 0xff))
    } else if n <= UInt64(UInt32.max) {
        out.append(mt | 26)
        for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((n >> UInt64(shift)) & 0xff)) }
    } else {
        out.append(mt | 27)
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((n >> UInt64(shift)) & 0xff)) }
    }
}

// MARK: - 解码

/// 解码整段字节为单个 CBOR 值；要求恰好消费完（无尾随数据）。
func decodeCBOR(_ data: Data) throws -> CBORValue {
    let bytes = [UInt8](data)
    var idx = 0
    let value = try parseItem(bytes, &idx)
    guard idx == bytes.count else { throw CBORError.trailingData }
    return value
}

private func parseItem(_ b: [UInt8], _ i: inout Int) throws -> CBORValue {
    guard i < b.count else { throw CBORError.truncated }
    let initial = b[i]
    i += 1
    let major = initial >> 5
    let ai = initial & 0x1f
    switch major {
    case 0:
        return .uint(try argument(ai, b, &i))
    case 3:
        let n = try argument(ai, b, &i)
        return .text(try readText(Int(n), b, &i))
    case 4:
        let n = try argument(ai, b, &i)
        var items = [CBORValue]()
        items.reserveCapacity(Int(n))
        for _ in 0..<n { items.append(try parseItem(b, &i)) }
        return .array(items)
    case 5:
        let n = try argument(ai, b, &i)
        var pairs = [(String, CBORValue)]()
        pairs.reserveCapacity(Int(n))
        for _ in 0..<n {
            let key = try parseItem(b, &i)
            guard case let .text(ks) = key else { throw CBORError.nonStringKey }
            pairs.append((ks, try parseItem(b, &i)))
        }
        return .map(pairs)
    case 7:
        switch ai {
        case 20: return .bool(false)
        case 21: return .bool(true)
        case 22: return .null
        default: throw CBORError.unsupported(initial)
        }
    default:
        throw CBORError.unsupported(initial)
    }
}

/// 读取头部后的参数（最小编码；不支持不定长 31）。
private func argument(_ ai: UInt8, _ b: [UInt8], _ i: inout Int) throws -> UInt64 {
    if ai < 24 { return UInt64(ai) }
    let count: Int
    switch ai {
    case 24: count = 1
    case 25: count = 2
    case 26: count = 4
    case 27: count = 8
    default: throw CBORError.unsupported(ai)
    }
    guard i + count <= b.count else { throw CBORError.truncated }
    var n: UInt64 = 0
    for _ in 0..<count { n = (n << 8) | UInt64(b[i]); i += 1 }
    return n
}

private func readText(_ n: Int, _ b: [UInt8], _ i: inout Int) throws -> String {
    guard n >= 0, i + n <= b.count else { throw CBORError.truncated }
    let slice = b[i..<(i + n)]
    i += n
    guard let s = String(bytes: slice, encoding: .utf8) else { throw CBORError.invalidUTF8 }
    return s
}
