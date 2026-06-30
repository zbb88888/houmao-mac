import AppKit

/// macOS-only bridge between `NSImage` and the platform-agnostic
/// `Attachment` Core model. Keeps AppKit out of the shared data layer so the
/// same `Attachment` type can be reused on iOS later.
extension Attachment {
    /// Encode an `NSImage` into a JPEG-backed attachment.
    /// - Parameter compressionFactor: JPEG quality, 0.0...1.0.
    static func image(_ nsImage: NSImage, compressionFactor: CGFloat = 0.85) -> Attachment? {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
        else { return nil }
        return .image(jpegData: jpeg)
    }

    /// Decode the stored image bytes back into an `NSImage` for rendering.
    var nsImage: NSImage? {
        guard case .image(let data) = content else { return nil }
        return NSImage(data: data)
    }
}
