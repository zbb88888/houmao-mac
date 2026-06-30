import Foundation

/// A file attached by the user before sending a query.
///
/// Platform-agnostic Core model: image payloads are stored as encoded `Data`
/// (JPEG bytes), never as `NSImage`/`UIImage`. Each platform shell is
/// responsible for converting its native image type into `Data`
/// (see `Attachment+AppKit.swift` on macOS) and for rendering it back.
struct Attachment: Identifiable {
    let id = UUID()
    let content: Content

    enum Content {
        /// JPEG-encoded image bytes.
        case image(data: Data)
        /// Raw audio bytes plus the original file name and format extension.
        case audio(name: String, data: Data, format: String)
    }

    /// Base64 payload used by the OpenAI-compatible API.
    var base64: String {
        switch content {
        case .image(let data):
            return data.base64EncodedString()
        case .audio(_, let data, _):
            return data.base64EncodedString()
        }
    }

    /// Build an image attachment from already-encoded JPEG bytes.
    static func image(jpegData: Data) -> Attachment {
        Attachment(content: .image(data: jpegData))
    }

    /// Build an audio attachment from a file URL (pure Foundation).
    static func audio(url: URL) -> Attachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Attachment(content: .audio(
            name: url.lastPathComponent,
            data: data,
            format: url.pathExtension.lowercased()
        ))
    }
}
