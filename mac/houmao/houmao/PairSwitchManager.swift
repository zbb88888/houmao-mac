import AppKit

extension Notification.Name {
    static let houmaoPairSwitchStackDidChange = Notification.Name("houmaoPairSwitchStackDidChange")
}

@MainActor
final class PairSwitchManager {
    static let shared = PairSwitchManager()

    private let dwellThreshold: TimeInterval = 10
    private let myBundleID = Bundle.main.bundleIdentifier

    private var observer: NSObjectProtocol?
    private var dwellTimer: Timer?
    private var uiTickTimer: Timer?
    private var state = PairSwitchDwellState()
    private var displayNameByBundleID: [String: String] = [:]

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.handleActivated(app)
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            handleActivated(app)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        dwellTimer?.invalidate()
        dwellTimer = nil
        uiTickTimer?.invalidate()
        uiTickTimer = nil
        state.resetPending()
    }

    func stackDisplayText() -> String {
        if let pendingID = state.pendingBundleID,
           let remaining = state.remaining(now: Date(), threshold: dwellThreshold) {
            let secs = max(0.1, remaining)
            return "候选：\(displayName(for: pendingID))（\(String(format: "%.1f", secs))s 后入栈）"
        }
        if state.stack.apps.isEmpty {
            return "等待收集（应用停留至少 10s）"
        }
        if state.stack.apps.count == 1 {
            return displayName(for: state.stack.apps[0])
        }
        return "\(displayName(for: state.stack.apps[0])) ↔ \(displayName(for: state.stack.apps[1]))"
    }

    func toggle() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let current = front.bundleIdentifier
        else { return }
        while let target = state.stack.toggleTarget(current: current) {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: target)
                .first(where: { !$0.isTerminated })
            {
                _ = app.activate(options: [.activateIgnoringOtherApps])
                return
            }

            state.stack.remove(target)
            NotificationCenter.default.post(name: .houmaoPairSwitchStackDidChange, object: nil)
        }
    }

    private func handleActivated(_ app: NSRunningApplication) {
        // Any app switch resets the pending dwell candidate.
        dwellTimer?.invalidate()
        dwellTimer = nil

        guard let bundleID = app.bundleIdentifier else { return }
        if let name = app.localizedName, !name.isEmpty {
            displayNameByBundleID[bundleID] = name
        }
        state.activated(bundleID: bundleID, isSelfApp: bundleID == myBundleID, now: Date())
        NotificationCenter.default.post(name: .houmaoPairSwitchStackDidChange, object: nil)

        if bundleID == myBundleID {
            uiTickTimer?.invalidate()
            uiTickTimer = nil
            return
        }

        startStatusTicking()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: dwellThreshold, repeats: false) { [weak self] _ in
            self?.commitPending()
        }
    }

    private func commitPending() {
        let committed = state.commitIfDue(now: Date(), threshold: dwellThreshold)
        uiTickTimer?.invalidate()
        uiTickTimer = nil
        if !committed { return }
        NotificationCenter.default.post(name: .houmaoPairSwitchStackDidChange, object: nil)
    }

    private func startStatusTicking() {
        uiTickTimer?.invalidate()
        uiTickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            NotificationCenter.default.post(name: .houmaoPairSwitchStackDidChange, object: nil)
        }
    }

    private func displayName(for bundleID: String) -> String {
        if let name = displayNameByBundleID[bundleID] {
            return name
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName,
           !name.isEmpty {
            displayNameByBundleID[bundleID] = name
            return name
        }
        return bundleID
    }
}
