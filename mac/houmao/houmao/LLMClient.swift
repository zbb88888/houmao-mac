import Foundation
import AppKit

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

/// Protocol for LLM clients.
nonisolated protocol LLMClient: Sendable {
    func ask(question: String, imageBase64s: [String]) async throws -> String
}

extension LLMClient {
    func ask(question: String) async throws -> String {
        try await ask(question: question, imageBase64s: [])
    }
}

/// Mock LLM client for testing.
nonisolated struct MockLLMClient: LLMClient {
    func ask(question: String, imageBase64s: [String]) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        let imgNote = imageBase64s.isEmpty ? "" : "（含 \(imageBase64s.count) 张图片）"
        return "Mock LLM 回复\(imgNote)：你刚才问的是「\(question)」。未来这里会接入 MiniCPM-V。"
    }
}
