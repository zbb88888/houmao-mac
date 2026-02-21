import Foundation
import AppKit
import HoumaoCore

/// 记录 App 切换事件和 houmao 输入，写入 HistoryStore。
final class UsageTracker {
    private let store: HistoryStore
    private let myBundleID = Bundle.main.bundleIdentifier

    private var appObserver: Any?

    // Thread-safe state using serial queue
    private let queue = DispatchQueue(label: "com.houmao.usagetracker", qos: .utility)
    private var currentAppName: String = "Unknown"
    private var previousAppName: String = "Unknown"
    private var isStarted = false

    init(store: HistoryStore) {
        self.store = store
    }

    deinit {
        if let obs = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Start

    /// Must be called explicitly to start monitoring
    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true

            DispatchQueue.main.async {
                self.setupMonitoring()
            }
        }
    }

    private func setupMonitoring() {
        let workspace = NSWorkspace.shared

        // Get initial app name
        if let front = workspace.frontmostApplication,
           let name = front.localizedName {
            queue.async {
                self.currentAppName = name
                self.previousAppName = name
            }
        }

        // App switch observer
        appObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let name = app.localizedName ?? "Unknown"
            let bundleID = app.bundleIdentifier
            self.handleAppSwitch(to: name, bundleID: bundleID)
        }
    }

    // MARK: - App Switch

    private func handleAppSwitch(to newAppName: String, bundleID: String?) {
        queue.async { [weak self] in
            guard let self else { return }

            let oldApp = self.currentAppName
            self.previousAppName = self.currentAppName
            self.currentAppName = newAppName

            // Don't record switches involving our own app
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

    /// Record text submitted from houmao's own input field.
    /// Can be called from any thread.
    func record(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        print("📝 UsageTracker.record() called with text: \(trimmed)")

        queue.async { [weak self] in
            guard let self else { return }

            print("📝 Creating record for app: \(self.previousAppName)")

            let record = UsageRecord(
                id: UUID(),
                timestamp: Date(),
                appName: self.previousAppName,
                text: trimmed
            )

            Task.detached(priority: .utility) { [store] in
                print("📝 Saving record to store...")
                await store.append(record)
                print("✅ Record saved")
            }
        }
    }
}
