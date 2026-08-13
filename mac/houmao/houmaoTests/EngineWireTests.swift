import Foundation
import Testing
@testable import houmao

// 引擎线格式：CBOR 子集编解码 / 分帧 / 协议消息映射。
// golden_* 为 Rust 引擎 ciborium 的真实输出（跨语言交叉验证）。

private func hexData(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

private let goldenHello = "a264747970656568656c6c6f6776657273696f6e01"
private let goldenResponse = "a3647479706568726573706f6e736562696462723166726573756c74a267636f6d6d616e646561626f72746a73657373696f6e5f6964627331"
private let goldenEvent = "a26474797065656576656e74656576656e74a364747970657073657373696f6e5f70726f67726573736a73657373696f6e5f69646273316870726f6772657373a364747970656f617373697374616e745f64656c74616a6d6573736167655f6964626d316564656c746166e4bda0e5a5bd"

// MARK: - CBOR 编解码

@Test func cborUintMinimalForms() throws {
    #expect(hex(encodeCBOR(.uint(1))) == "01")
    #expect(hex(encodeCBOR(.uint(23))) == "17")
    #expect(hex(encodeCBOR(.uint(24))) == "1818")
    #expect(hex(encodeCBOR(.uint(255))) == "18ff")
    #expect(hex(encodeCBOR(.uint(256))) == "190100")
    #expect(hex(encodeCBOR(.uint(65536))) == "1a00010000")
    for n: UInt64 in [0, 23, 24, 255, 256, 65535, 65536, 4_294_967_296] {
        #expect(try decodeCBOR(encodeCBOR(.uint(n))) == .uint(n))
    }
}

@Test func cborTextRoundTripIncludingMultibyte() throws {
    for s in ["", "hi", "你好", "emoji😀"] {
        #expect(try decodeCBOR(encodeCBOR(.text(s))) == .text(s))
    }
}

@Test func cborNestedRoundTrip() throws {
    let v: CBORValue = .map([
        ("type", .text("x")),
        ("items", .array([.uint(1), .text("a"), .bool(true), .null])),
        ("flag", .bool(false)),
    ])
    #expect(try decodeCBOR(encodeCBOR(v)) == v)
}

@Test func cborDecodesRealCiboriumHello() throws {
    let v = try decodeCBOR(hexData(goldenHello))
    #expect(v["type"]?.stringValue == "hello")
    #expect(v["version"]?.uintValue == 1)
}

@Test func cborRejectsTrailingData() {
    let bytes = encodeCBOR(.uint(1)) + Data([0x00])
    #expect(throws: CBORError.self) { try decodeCBOR(bytes) }
}

// MARK: - 分帧

@Test func framingRoundTrip() throws {
    let payload = Data([1, 2, 3, 4, 5])
    let framed = EngineFraming.frame(payload)
    #expect(framed.count == 4 + payload.count)
    let decoder = EngineFraming.Decoder()
    #expect(try decoder.push(framed) == [payload])
}

@Test func framingHandlesSplitAndCoalescedChunks() throws {
    let a = EngineFraming.frame(Data([0xaa]))
    let b = EngineFraming.frame(Data([0xbb, 0xcc]))
    let stream = a + b
    let decoder = EngineFraming.Decoder()
    // 逐字节喂入，验证任意切分下仍能重组。
    var frames = [Data]()
    for byte in stream {
        frames.append(contentsOf: try decoder.push(Data([byte])))
    }
    #expect(frames == [Data([0xaa]), Data([0xbb, 0xcc])])
}

// MARK: - 协议编码（client → server）

@Test func clientHelloEncodesToGolden() {
    let framedless = encodeCBOR(EngineClientMessage.hello(version: engineProtocolVersion, uiTools: []).cbor)
    #expect(hex(framedless) == goldenHello)
}

@Test func createCommandRoundTripsThroughCbor() throws {
    let msg = EngineClientMessage.request(id: "r1", command: .create(name: "n", model: EngineModelRef(provider: "p", id: "m")))
    let decoded = try decodeCBOR(encodeCBOR(msg.cbor))
    #expect(decoded["type"]?.stringValue == "request")
    #expect(decoded["id"]?.stringValue == "r1")
    #expect(decoded["command"]?["command"]?.stringValue == "create")
    #expect(decoded["command"]?["model"]?["provider"]?.stringValue == "p")
}

// MARK: - 协议解码（server → client，用真实 ciborium 字节）

@Test func decodesRealResponse() throws {
    let msg = try EngineServerMessage.decode(frame: hexData(goldenResponse))
    #expect(msg == .response(id: "r1", result: .abort(sessionId: "s1")))
}

@Test func decodesRealProgressEventAndStripReady() throws {
    let msg = try EngineServerMessage.decode(frame: hexData(goldenEvent))
    #expect(msg == .event(.sessionProgress(sessionId: "s1", progress: .assistantDelta(messageId: "m1", delta: "你好"))))
}
