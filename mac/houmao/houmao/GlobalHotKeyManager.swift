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
    /// Posted by the view model when `/mail` is entered so the app can open the
    /// standalone mail-cleanup window (mirrors the chat window shell).
    static let houmaoEnterMailWindow = Notification.Name("houmaoEnterMailWindow")
    /// Posted when the PR button is tapped so the app can open the standalone
    /// PR panel window (mirrors the mail window shell).
    static let houmaoEnterPRWindow = Notification.Name("houmaoEnterPRWindow")
    /// Posted when the Issue button is tapped so the app can open the standalone
    /// Issue panel window (mirrors the PR window shell).
    static let houmaoEnterIssueWindow = Notification.Name("houmaoEnterIssueWindow")
    /// Posted when the Do button (or `/do`) is used so the app can open the
    /// standalone Do panel window (mirrors the Issue window shell).
    static let houmaoEnterDoWindow = Notification.Name("houmaoEnterDoWindow")
    /// Posted when the editor button is tapped so the app can open the shared,
    /// general-purpose Markdown editor window with a blank scratch document
    /// (saved to the daily notes file). Views that need to edit specific content
    /// call `AppDelegate.presentMarkdownEditor` directly instead.
    static let houmaoEnterEditorWindow = Notification.Name("houmaoEnterEditorWindow")
    /// Posted by the editor's save button to persist the current document and
    /// close the shared editor window.
    static let houmaoCommitEditor = Notification.Name("houmaoCommitEditor")
    /// Posted when the Goals button (or `/goals`) is used so the app can open the
    /// standalone goal-management window (mirrors the Do window shell).
    static let houmaoEnterGoalsWindow = Notification.Name("houmaoEnterGoalsWindow")
    /// Posted when the work-log button (or `/worklog`) is used so the app can open
    /// the standalone work-log window (mirrors the PR window shell).
    static let houmaoEnterWorkLogWindow = Notification.Name("houmaoEnterWorkLogWindow")
    /// Posted when the user opens a message so the app can show the standalone
    /// mail-detail window (a standard large window, not an in-place sheet).
    static let houmaoOpenMailDetail = Notification.Name("houmaoOpenMailDetail")
    /// Posted when the mail-detail window should be closed (e.g. the user hit
    /// ESC), so it closes via the same path as its title-bar close button.
    static let houmaoCloseMailDetail = Notification.Name("houmaoCloseMailDetail")
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
