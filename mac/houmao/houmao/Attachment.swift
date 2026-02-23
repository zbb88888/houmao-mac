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
