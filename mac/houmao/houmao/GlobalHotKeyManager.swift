import AppKit

extension Notification.Name {
    /// Posted when the main window is shown after being hidden.
    static let houmaoWindowDidShow = Notification.Name("houmaoWindowDidShow")
    /// Posted by the view model when chat mode is entered (via `/chat` or the
    /// automatic upgrade after the 3rd one-shot turn) so the app can hide the
    /// minimal input box and open the standalone, resizable chat window.
    static let houmaoEnterChatWindow = Notification.Name("houmaoEnterChatWindow")
    /// Posted by the view model when chat mode is exited so the app can close
    /// the standalone chat window.
    static let houmaoExitChatWindow = Notification.Name("houmaoExitChatWindow")
    /// Posted by the app after the standalone chat window becomes visible so the
    /// chat input can grab keyboard focus.
    static let houmaoChatWindowDidShow = Notification.Name("houmaoChatWindowDidShow")
}

/// Listens for double-tap Option key to show/hide main window.
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastOptionPressTime: TimeInterval = 0
    private var optionKeyState: Bool = false

    private let doubleClickInterval: TimeInterval = 0.4
    private let minPressInterval: TimeInterval = 0.05
    private let leftOptionKeyCode: UInt16 = 58
    private let rightOptionKeyCode: UInt16 = 61

    private init() {
        // Monitor both local and global events
        setupLocalMonitor()
        setupGlobalMonitor()
    }

    private func setupLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func setupGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isOptionKey = event.keyCode == leftOptionKeyCode || event.keyCode == rightOptionKeyCode
        let isOptionPressed = event.modifierFlags.contains(.option)

        guard isOptionKey else { return }

        // Detect Option key press (transition from released to pressed)
        if isOptionPressed && !optionKeyState {
            let now = Date().timeIntervalSince1970
            let timeSinceLastPress = now - lastOptionPressTime

            if timeSinceLastPress < doubleClickInterval && timeSinceLastPress > minPressInterval {
                toggleMainWindow()
                lastOptionPressTime = 0
            } else {
                lastOptionPressTime = now
            }
            optionKeyState = true
        } else if !isOptionPressed && optionKeyState {
            optionKeyState = false
        }
    }

    private func toggleMainWindow() {
        DispatchQueue.main.async {
            guard let appDelegate = AppDelegate.shared,
                  let panel = appDelegate.mainPanel else { return }

            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                appDelegate.showMainPanel()
            }
        }
    }

    // Cleanup monitors (for explicit shutdown if needed)
    func cleanup() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
}
