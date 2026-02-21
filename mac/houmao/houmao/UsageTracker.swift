import Foundation
import AppKit
import HoumaoCore

/// 记录用户在其他 app 中的输入。
/// 累积按键字符，回车时提交。对支持 AX 的 app 读取最终文本（含中文）。
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

    /// 回车时调用：尝试 AX 读最终文本（含中文），失败或过长则用按键字符。
    private func commitInput() {
        guard !isOwnApp else { return }

        let keystrokes = keystrokeBuffer
        keystrokeBuffer = ""
        guard !keystrokes.isEmpty else { return }

        // AX 读文本框内容（能拿到中文），但如果内容远长于按键数，说明读到了整个编辑器，回退用按键
        var text = keystrokes
        if let axText = readFocusedText(), axText.count <= keystrokes.count * 3 {
            text = axText
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
        guard AXIsProcessTrusted(), currentAppPID > 0 else { return nil }

        let appElement = AXUIElementCreateApplication(currentAppPID)
        var focusedRef: AnyObject?
        var err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )

        if err != .success {
            var winRef: AnyObject?
            if AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &winRef
            ) == .success, let winRef {
                err = AXUIElementCopyAttributeValue(
                    winRef as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
                )
            }
        }

        if err != .success || focusedRef == nil {
            err = AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef
            )
        }

        guard err == .success, let focusedRef else { return nil }

        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, Self.nonTextRoles.contains(role) { return nil }

        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
           let text = ref as? String, !text.isEmpty { return text }

        return nil
    }

    // MARK: - App Switch

    private func handleAppSwitch(to newAppName: String, bundleID: String?, pid: pid_t) {
        queue.async { [weak self] in
            guard let self else { return }

            // 未回车的输入直接丢弃
            self.keystrokeBuffer = ""

            let oldApp = self.currentAppName
            self.previousAppName = self.currentAppName
            self.currentAppName = newAppName
            self.currentAppPID = pid
            self.isOwnApp = (bundleID == self.myBundleID)

            guard bundleID != self.myBundleID else { return }

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

    // MARK: - Manual record (houmao input)

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
