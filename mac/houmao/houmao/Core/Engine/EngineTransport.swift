import Darwin
import Foundation

/// 阻塞式 Unix domain socket 传输，连引擎。后台线程读帧经 `onFrame` 交付；
/// `send` 在调用方线程写。非 @MainActor——回调可能在非主线程触发，调用方需自行跳主线程。
///
/// 用法约束：`onFrame`/`onClose` 必须在 `connect` 之前设置好（之后读线程才启动）。
final class EngineTransport: @unchecked Sendable {
    private var fd: Int32 = -1
    private var readThread: Thread?
    private let sendLock = NSLock()
    private var closed = false

    var onFrame: (@Sendable (Data) -> Void)?
    var onClose: (@Sendable () -> Void)?

    func connect(path: String) throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw EngineTransportError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(sock)
            throw EngineTransportError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { d in
                pathBytes.withUnsafeBufferPointer { src in
                    d.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, len)
            }
        }
        guard result == 0 else {
            let e = errno
            Darwin.close(sock)
            throw EngineTransportError.connectFailed(e)
        }
        fd = sock
        startReadLoop()
    }

    private func startReadLoop() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "houmao.engine.read"
        thread.stackSize = 512 * 1024
        readThread = thread
        thread.start()
    }

    private func readLoop() {
        let decoder = EngineFraming.Decoder()
        let bufSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, bufSize) }
            if n <= 0 { break }
            let chunk = Data(buffer[0..<n])
            if let frames = try? decoder.push(chunk) {
                for frame in frames { onFrame?(frame) }
            }
        }
        onClose?()
    }

    /// 写已加帧的字节。
    func send(_ data: Data) {
        sendLock.lock(); defer { sendLock.unlock() }
        guard fd >= 0, !closed else { return }
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n <= 0 { break }
                p = p.advanced(by: n)
                remaining -= n
            }
        }
    }

    func close() {
        sendLock.lock()
        guard !closed else { sendLock.unlock(); return }
        closed = true
        let f = fd
        fd = -1
        sendLock.unlock()
        if f >= 0 { Darwin.close(f) } // 关闭 fd 会让 readLoop 的 read 返回而退出
    }
}

enum EngineTransportError: Error {
    case socketFailed(Int32)
    case pathTooLong
    case connectFailed(Int32)
}
