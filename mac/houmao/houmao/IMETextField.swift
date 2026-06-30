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

// MARK: - Multi-line chat input (NSTextView)

/// IME-safe, multi-line chat input used by `/chat` mode's bottom bar.
///
/// Standard messenger behaviour: `Return` submits, `Shift+Return` inserts a
/// newline. The view reports its laid-out content height through
/// `measuredHeight` so the SwiftUI container grows from one line up to
/// `maxHeight`, then scrolls — matching WeChat / Chatbox input fields.
struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    var font: NSFont = .systemFont(ofSize: 15)
    var maxHeight: CGFloat = 120
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.string = text

        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let isComposing = textView.hasMarkedText()
        if !isComposing && textView.string != text {
            textView.string = text
        }

        context.coordinator.onSubmit = onSubmit
        context.coordinator.recomputeHeight()

        if isFocused, let window = textView.window, window.firstResponder !== textView {
            DispatchQueue.main.async { window.makeFirstResponder(textView) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            measuredHeight: $measuredHeight,
            maxHeight: maxHeight,
            font: font
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        let isFocused: Binding<Bool>
        let measuredHeight: Binding<CGFloat>
        let maxHeight: CGFloat
        let font: NSFont
        var onSubmit: (() -> Void)?
        weak var textView: NSTextView?

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            measuredHeight: Binding<CGFloat>,
            maxHeight: CGFloat,
            font: NSFont
        ) {
            self.text = text
            self.isFocused = isFocused
            self.measuredHeight = measuredHeight
            self.maxHeight = maxHeight
            self.font = font
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            recomputeHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        /// Recompute the laid-out content height and publish it, clamped to a
        /// single line minimum and `maxHeight` maximum.
        func recomputeHeight() {
            guard let tv = textView,
                  let layoutManager = tv.layoutManager,
                  let container = tv.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = tv.textContainerInset.height * 2
            let oneLine = ceil(font.boundingRectForFont.height) + inset
            let height = min(maxHeight, max(oneLine, ceil(used) + inset))
            if abs(measuredHeight.wrappedValue - height) > 0.5 {
                let value = height
                DispatchQueue.main.async { self.measuredHeight.wrappedValue = value }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Never submit/insert while an IME candidate is being composed.
            guard !textView.hasMarkedText() else { return false }

            let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shiftHeld {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            text.wrappedValue = textView.string
            onSubmit?()
            return true
        }
    }
}
