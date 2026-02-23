import Foundation
import AppKit

/// A file attached by the user before sending a query.
struct Attachment: Identifiable {
    let id = UUID()
    let content: Content

    enum Content {
        case image(nsImage: NSImage, base64: String)
        case audio(name: String, base64: String, format: String)
    }

    static func image(_ nsImage: NSImage, compressionFactor: CGFloat = 0.85) -> Attachment? {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
        else { return nil }
        return Attachment(content: .image(nsImage: nsImage, base64: jpeg.base64EncodedString()))
    }

    static func audio(url: URL) -> Attachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Attachment(content: .audio(
            name: url.lastPathComponent,
            base64: data.base64EncodedString(),
            format: url.pathExtension.lowercased()
        ))
    }
}

/// Protocol for LLM clients.
nonisolated protocol LLMClient: Sendable {
    func ask(question: String, attachments: [Attachment]) async throws -> String
}

/// Mock LLM client for testing.
nonisolated struct MockLLMClient: LLMClient {
    func ask(question: String, attachments: [Attachment]) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        let note = attachments.isEmpty ? "" : " (with \(attachments.count) attachments)"
        return "Mock LLM reply\(note): You just asked: \"\(question)\". This will integrate with MiniCPM-V in the future."
    }
}
