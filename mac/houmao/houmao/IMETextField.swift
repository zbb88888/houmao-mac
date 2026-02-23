import SwiftUI
import AppKit

struct IMETextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 18, weight: .medium)
    var onSubmit: (() -> Void)?
    var onUpArrow: (() -> String?)?
    var onDownArrow: (() -> String?)?

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
        let isComposing = (nsView.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !isComposing && nsView.stringValue != text {
            nsView.stringValue = text
        }

        let coord = context.coordinator
        coord.onSubmit = onSubmit
        coord.onUpArrow = onUpArrow
        coord.onDownArrow = onDownArrow

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

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
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
