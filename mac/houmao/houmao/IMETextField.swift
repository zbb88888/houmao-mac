import SwiftUI
import AppKit

/// AppKit-backed text field that correctly handles CJK Input Method (IME) composition.
///
/// SwiftUI's `TextField.onSubmit` can fire while the IME is still composing,
/// capturing raw pinyin instead of the final Chinese characters.
/// This wrapper uses `NSTextFieldDelegate` to only submit when composition is complete.
struct IMETextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 18, weight: .medium)
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
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
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Avoid overwriting text while IME is composing
        let isComposing = (nsView.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !isComposing && nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onSubmit = onSubmit

        if isFocused && nsView.window != nil {
            DispatchQueue.main.async {
                if nsView.window?.firstResponder != nsView.currentEditor() {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, isFocused: Binding<Bool>, onSubmit: (() -> Void)?) {
            self.text = text
            self.isFocused = isFocused
            self.onSubmit = onSubmit
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
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Let the IME finish composing before we submit
                if textView.hasMarkedText() {
                    return false
                }
                // Fire submit when composition is complete
                text.wrappedValue = (control as? NSTextField)?.stringValue ?? ""
                onSubmit?()
                return true
            }
            return false
        }
    }
}
