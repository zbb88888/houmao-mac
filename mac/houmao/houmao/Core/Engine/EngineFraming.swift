import Foundation

/// 帧编解码：`[4 字节大端无符号长度][CBOR 载荷]`，与 Rust 引擎 `framing.rs` 对齐。
enum EngineFraming {
    /// 单帧载荷上限（16 MiB），与引擎一致。
    static let maxFrameLen: UInt32 = 16 * 1024 * 1024

    /// 给载荷加 4 字节大端长度前缀。
    static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        let len = UInt32(payload.count)
        out.append(UInt8((len >> 24) & 0xff))
        out.append(UInt8((len >> 16) & 0xff))
        out.append(UInt8((len >> 8) & 0xff))
        out.append(UInt8(len & 0xff))
        out.append(payload)
        return out
    }

    /// 增量分帧：喂入任意切分的字节流，产出完整帧载荷。
    final class Decoder {
        private var buffer = Data()

        /// 追加一段字节，返回本次可提取的完整帧载荷（可能 0 或多个）。
        /// 声明长度超上限则抛错。
        func push(_ chunk: Data) throws -> [Data] {
            buffer.append(chunk)
            var frames = [Data]()
            while buffer.count >= 4 {
                let len = (UInt32(buffer[buffer.startIndex]) << 24)
                    | (UInt32(buffer[buffer.startIndex + 1]) << 16)
                    | (UInt32(buffer[buffer.startIndex + 2]) << 8)
                    | UInt32(buffer[buffer.startIndex + 3])
                if len > maxFrameLen { throw CBORError.unsupported(0) }
                let total = 4 + Int(len)
                guard buffer.count >= total else { break }
                let payload = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + total))
                frames.append(payload)
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
            }
            return frames
        }
    }
}
