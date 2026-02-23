import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ImageAwareTextField (NSTextField subclass for drag-and-drop)

class ImageAwareTextField: NSTextField {
    var onPasteImages: (([NSImage]) -> Void)?
    var onDropAudios: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if Self.hasAudioContent(pb) || Self.hasImageContent(pb) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // Check audio files first
        let audioURLs = Self.extractAudioURLs(from: pb)
        if !audioURLs.isEmpty {
            onDropAudios?(audioURLs)
        }

        // Then check images
        let images = Self.extractImages(from: pb)
        if !images.isEmpty {
            onPasteImages?(images)
        }

        if !audioURLs.isEmpty || !images.isEmpty {
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: - Audio extraction helpers

    static func hasAudioContent(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.audio.identifier]
        ]) as? [URL], !urls.isEmpty {
            return true
        }
        return false
    }

    static func extractAudioURLs(from pb: NSPasteboard) -> [URL] {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.audio.identifier]
        ]) as? [URL] else { return [] }
        return urls
    }

    // MARK: - Image extraction helpers

    static func hasImageContent(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL], !urls.isEmpty {
            return true
        }
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
            return true
        }
        return false
    }

    static func extractImages(from pb: NSPasteboard) -> [NSImage] {
        var images: [NSImage] = []

        // 1. File URLs (Finder drag, file copy)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL] {
            for url in urls {
                if let img = NSImage(contentsOf: url) {
                    images.append(img)
                }
            }
        }

        // 2. Raw image data (screenshot paste)
        if images.isEmpty {
            if let pngData = pb.data(forType: .png), let img = NSImage(data: pngData) {
                images.append(img)
            } else if let tiffData = pb.data(forType: .tiff), let img = NSImage(data: tiffData) {
                images.append(img)
            }
        }

        return images
    }
}

// MARK: - IMETextField (SwiftUI wrapper)

struct IMETextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 18, weight: .medium)
    var onSubmit: (() -> Void)?
    var onUpArrow: (() -> String?)?
    var onDownArrow: (() -> String?)?
    var onPasteImages: (([NSImage]) -> Void)?
    var onDropAudios: (([URL]) -> Void)?

    func makeNSView(context: Context) -> ImageAwareTextField {
        let tf = ImageAwareTextField()
        tf.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: font,
            ]
        )
        tf.font = font
        tf.textColor = .labelColor
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.cell?.isScrollable = true
        tf.delegate = context.coordinator
        tf.onPasteImages = onPasteImages
        tf.onDropAudios = onDropAudios
        return tf
    }

    func updateNSView(_ nsView: ImageAwareTextField, context: Context) {
        let isComposing = (nsView.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !isComposing && nsView.stringValue != text {
            nsView.stringValue = text
        }

        let coord = context.coordinator
        coord.onSubmit = onSubmit
        coord.onUpArrow = onUpArrow
        coord.onDownArrow = onDownArrow
        coord.onPasteImages = onPasteImages
        coord.onDropAudios = onDropAudios
        nsView.onPasteImages = onPasteImages
        nsView.onDropAudios = onDropAudios

        if isFocused, let window = nsView.window {
            DispatchQueue.main.async {
                if window.firstResponder != nsView.currentEditor() {
                    window.makeFirstResponder(nsView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>
        let isFocused: Binding<Bool>
        var onSubmit: (() -> Void)?
        var onUpArrow: (() -> String?)?
        var onDownArrow: (() -> String?)?
        var onPasteImages: (([NSImage]) -> Void)?
        var onDropAudios: (([URL]) -> Void)?

        private var pasteMonitor: Any?

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
            super.init()
            installPasteMonitor()
        }

        deinit {
            if let monitor = pasteMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func installPasteMonitor() {
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.charactersIgnoringModifiers == "v" {
                    let pb = NSPasteboard.general
                    let images = ImageAwareTextField.extractImages(from: pb)
                    if !images.isEmpty {
                        self.onPasteImages?(images)
                        // If pasteboard also has text, let the default paste proceed
                        if pb.string(forType: .string) != nil {
                            return event
                        }
                        // Image-only paste: consume the event
                        return nil
                    }
                }
                return event
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            text.wrappedValue = tf.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isFocused.wrappedValue = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                text.wrappedValue = (control as? NSTextField)?.stringValue ?? ""
                onSubmit?()
                return true

            case #selector(NSResponder.moveUp(_:)):
                return handleArrow(onUpArrow, control: control, textView: textView)

            case #selector(NSResponder.moveDown(_:)):
                return handleArrow(onDownArrow, control: control, textView: textView)

            default:
                return false
            }
        }

        private func handleArrow(_ handler: (() -> String?)?, control: NSControl, textView: NSTextView) -> Bool {
            guard let command = handler?(), let textField = control as? NSTextField else { return true }
            text.wrappedValue = command
            textField.stringValue = command
            textView.moveToEndOfLine(nil)
            return true
        }
    }
}
