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
    /// Posted when the agent inbox button (or `/agent`), or a proactive-agent
    /// notification, is used so the app can open the standalone agent inbox
    /// window (主观能动性「动态」; mirrors the Issue window shell).
    static let houmaoEnterAgentWindow = Notification.Name("houmaoEnterAgentWindow")
    /// Posted by `JobStore` when a background agent job (§7 document-mediated
    /// tool) finishes, so the agent window can resume and read the result doc.
    static let houmaoAgentJobFinished = Notification.Name("houmaoAgentJobFinished")
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

    var onDoubleControl: (() -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var lastOptionPressTime: TimeInterval = 0
    private var optionKeyState: Bool = false
    private var lastControlPressTime: TimeInterval = 0
    private var controlKeyState: Bool = false
    private var suppressControlDoubleTapUntil: TimeInterval = 0

    private let doubleClickInterval: TimeInterval = 0.4
    private let minPressInterval: TimeInterval = 0.05
    private let leftOptionKeyCode: UInt16 = 58
    private let rightOptionKeyCode: UInt16 = 61
    private let leftControlKeyCode: UInt16 = 59
    private let rightControlKeyCode: UInt16 = 62
    private let controlArrowSuppressInterval: TimeInterval = 0.35

    private init() {
        // Monitor both local and global events
        setupLocalMonitor()
        setupGlobalMonitor()
        setupLocalKeyDownMonitor()
        setupGlobalKeyDownMonitor()
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

    private func setupLocalKeyDownMonitor() {
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
    }

    private func setupGlobalKeyDownMonitor() {
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        handleControlDoubleTap(event)

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

    private func handleControlDoubleTap(_ event: NSEvent) {
        let isControlKey = event.keyCode == leftControlKeyCode || event.keyCode == rightControlKeyCode
        let isControlPressed = event.modifierFlags.contains(.control)

        guard isControlKey else { return }
        guard event.modifierFlags.intersection([.command, .option, .shift, .function]).isEmpty else {
            controlKeyState = isControlPressed
            return
        }

        if isControlPressed && !controlKeyState {
            let now = Date().timeIntervalSince1970
            let timeSinceLastPress = now - lastControlPressTime
            if now >= suppressControlDoubleTapUntil &&
                timeSinceLastPress < doubleClickInterval &&
                timeSinceLastPress > minPressInterval {
                DispatchQueue.main.async { [weak self] in
                    self?.onDoubleControl?()
                }
                lastControlPressTime = 0
            } else {
                lastControlPressTime = now
            }
            controlKeyState = true
        } else if !isControlPressed && controlKeyState {
            controlKeyState = false
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Ignore a control double tap shortly after Ctrl+Arrow desktop switching.
        let isArrow = event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126
        guard isArrow, event.modifierFlags.contains(.control) else { return }
        suppressControlDoubleTapUntil = Date().timeIntervalSince1970 + controlArrowSuppressInterval
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
        if let monitor = localKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyDownMonitor = nil
        }
        if let monitor = globalKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyDownMonitor = nil
        }
    }
}
