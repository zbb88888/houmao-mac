import AppKit
import os.log

private let axLog = Logger(subsystem: "com.houmao", category: "AXRead")

/// Tracks user input in other apps.
/// Accumulates keystrokes, commits on Enter. Reads final text via AX for CJK support.
final class UsageTracker {
    private let store: HistoryStore
    private let myBundleID = Bundle.main.bundleIdentifier

    private var appObserver: Any?
    private var keystrokeMonitor: Any?

    // All mutable state on `queue`
    private let queue = DispatchQueue(label: "com.houmao.usagetracker", qos: .utility)
    private var currentAppName: String = "Unknown"
    private var previousAppName: String = "Unknown"
    private var currentAppPID: pid_t = 0
    private var isStarted = false
    private var isOwnApp = false

    private var keystrokeBuffer: String = ""

    init(store: HistoryStore) {
        self.store = store
    }

    deinit {
        if let obs = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let monitor = keystrokeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            DispatchQueue.main.async { self.setupMonitoring() }
        }
    }

    private func setupMonitoring() {
        if let front = NSWorkspace.shared.frontmostApplication,
           let name = front.localizedName {
            let isSelf = front.bundleIdentifier == myBundleID
            let pid = front.processIdentifier
            queue.async {
                self.currentAppName = name
                self.previousAppName = name
                self.currentAppPID = pid
                self.isOwnApp = isSelf
            }
        }

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.handleAppSwitch(
                to: app.localizedName ?? "Unknown",
                bundleID: app.bundleIdentifier,
                pid: app.processIdentifier
            )
        }

        keystrokeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return }

            let isEnter = event.keyCode == 36 || event.keyCode == 76

            if isEnter {
                self.queue.async { self.commitInput() }
                return
            }

            guard let chars = event.characters, !chars.isEmpty else { return }
            let printable = String(chars.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            })
            guard !printable.isEmpty else { return }
            self.queue.async {
                guard !self.isOwnApp else { return }
                self.keystrokeBuffer += printable
            }
        }
    }

    // MARK: - Commit

    /// Commits input on Enter: tries reading final text via AX (for CJK), falls back to keystrokes.
    private func commitInput() {
        guard !isOwnApp else { return }

        let keystrokes = keystrokeBuffer
        keystrokeBuffer = ""
        guard !keystrokes.isEmpty else { return }

        axLog.debug("commitInput: keystrokes=\(keystrokes.count) chars")

        // Try reading via AX (gets CJK chars), but if text is much longer than keystrokes, fallback
        var text = keystrokes
        if let axText = readFocusedText(), axText.count <= keystrokes.count * 3 {
            axLog.debug("commitInput: using AX text='\(axText)'")
            text = axText
        } else {
            axLog.debug("commitInput: using keystrokes (AX failed or too long)")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let record = UsageRecord(
            id: UUID(),
            timestamp: Date(),
            appName: currentAppName,
            text: trimmed
        )
        Task.detached(priority: .utility) { [store] in
            await store.append(record)
        }
    }

    // MARK: - AX Text Reading

    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem",
        "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXToolbar",
        "AXImage", "AXScrollBar", "AXSplitter", "AXTabGroup",
        "AXTab", "AXOutline", "AXRow", "AXColumn", "AXTable",
        "AXBrowser", "AXList", "AXGroup", "AXSplitGroup",
    ]

    private func readFocusedText() -> String? {
        guard AXIsProcessTrusted(), currentAppPID > 0 else {
            axLog.debug("readFocusedText: not trusted or pid=0")
            return nil
        }

        let appElement = AXUIElementCreateApplication(currentAppPID)
        var focusedRef: AnyObject?
        var err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        axLog.debug("readFocusedText: focusedElement from app err=\(err.rawValue)")

        if err != .success {
            var winRef: AnyObject?
            if AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &winRef
            ) == .success, let winRef {
                err = AXUIElementCopyAttributeValue(
                    winRef as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
                )
                axLog.debug("readFocusedText: focusedElement from window err=\(err.rawValue)")
            }
        }

        if err != .success || focusedRef == nil {
            err = AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef
            )
            axLog.debug("readFocusedText: focusedElement from systemWide err=\(err.rawValue)")
        }

        guard err == .success, let focusedRef else {
            axLog.debug("readFocusedText: no focused element found")
            return nil
        }

        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "<nil>"
        axLog.debug("readFocusedText: role=\(role)")
        if Self.nonTextRoles.contains(role) { return nil }

        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
           let text = ref as? String, !text.isEmpty {
            axLog.debug("readFocusedText: got value len=\(text.count)")
            return text
        }

        axLog.debug("readFocusedText: no value attribute")
        return nil
    }

    // MARK: - App Switch

    private func handleAppSwitch(to newAppName: String, bundleID: String?, pid: pid_t) {
        queue.async { [weak self] in
            guard let self, bundleID != self.myBundleID else { return }

            // Discard uncommitted input
            self.keystrokeBuffer = ""

            let oldApp = self.currentAppName
            self.previousAppName = self.currentAppName
            self.currentAppName = newAppName
            self.currentAppPID = pid
            self.isOwnApp = false

            let record = UsageRecord(
                id: UUID(),
                timestamp: Date(),
                appName: newAppName,
                text: "[切换] \(oldApp) → \(newAppName)"
            )
            Task.detached(priority: .utility) { [store] in
                await store.append(record)
            }
        }
    }

    // MARK: - Manual record (for houmao's own input)

    func record(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let record = UsageRecord(
                id: UUID(),
                timestamp: Date(),
                appName: self.previousAppName,
                text: trimmed
            )
            Task.detached(priority: .utility) { [store] in
                await store.append(record)
            }
        }
    }
}
