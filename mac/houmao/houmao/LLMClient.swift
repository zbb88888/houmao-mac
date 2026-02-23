import Foundation
import AppKit
import AVFoundation

/// An image attached by the user before sending a query.
struct AttachedImage: Identifiable {
    let id = UUID()
    let nsImage: NSImage
    let base64JPEG: String

    init?(image: NSImage, compressionFactor: CGFloat = 0.85) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
        else { return nil }
        self.nsImage = image
        self.base64JPEG = jpeg.base64EncodedString()
    }
}

/// An audio file attached by the user before sending a query.
struct AttachedAudio: Identifiable {
    let id = UUID()
    let fileName: String
    let duration: TimeInterval
    let base64Data: String
    let format: String

    init?(url: URL) {
        self.fileName = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Get duration synchronously via AVAudioFile when possible, fallback to 0
        if let audioFile = try? AVAudioFile(forReading: url) {
            let frames = Double(audioFile.length)
            let sampleRate = audioFile.processingFormat.sampleRate
            self.duration = sampleRate > 0 ? frames / sampleRate : 0
        } else {
            self.duration = 0
        }
        self.base64Data = data.base64EncodedString()
        self.format = url.pathExtension.lowercased()
    }
}

/// Protocol for LLM clients.
nonisolated protocol LLMClient: Sendable {
    func ask(question: String, imageBase64s: [String], audioBase64s: [(data: String, format: String)]) async throws -> String
}

extension LLMClient {
    func ask(question: String) async throws -> String {
        try await ask(question: question, imageBase64s: [], audioBase64s: [])
    }

    func ask(question: String, imageBase64s: [String]) async throws -> String {
        try await ask(question: question, imageBase64s: imageBase64s, audioBase64s: [])
    }
}

/// Mock LLM client for testing.
nonisolated struct MockLLMClient: LLMClient {
    func ask(question: String, imageBase64s: [String], audioBase64s: [(data: String, format: String)]) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        let imgNote = imageBase64s.isEmpty ? "" : "（含 \(imageBase64s.count) 张图片）"
        let audioNote = audioBase64s.isEmpty ? "" : "（含 \(audioBase64s.count) 个音频）"
        return "Mock LLM 回复\(imgNote)\(audioNote)：你刚才问的是「\(question)」。未来这里会接入 MiniCPM-V。"
    }
}
