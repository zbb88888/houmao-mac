import Foundation
import AppKit
import HoumaoCore

/// 采集全局键盘输入、App 切换事件，并写入 HistoryStore。
final class UsageTracker {
    private let store: HistoryStore
    private let myBundleID = Bundle.main.bundleIdentifier

    private var appObserver: Any?
    private var keyMonitor: Any?

    // Thread-safe state using serial queue
    private let queue = DispatchQueue(label: "com.houmao.usagetracker", qos: .utility)
    private var currentAppName: String = "Unknown"
    private var previousAppName: String = "Unknown"
    private var currentBuffer: String = ""
    private var isStarted = false

    // Auto-commit timer
    private var commitTimer: DispatchSourceTimer?
    private let autoCommitInterval: TimeInterval = 5.0

    init(store: HistoryStore) {
        self.store = store
    }

    deinit {
        queue.sync {
            commitTimer?.cancel()
        }
        if let obs = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
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

        // Global keyboard monitor
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        if keyMonitor == nil {
            print("UsageTracker: global key monitor failed, accessibility permission may be needed")
        }

        // Auto-commit timer: commit buffer every N seconds
        setupAutoCommitTimer()
    }

    private func setupAutoCommitTimer() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.autoCommitInterval, repeating: self.autoCommitInterval)
            timer.setEventHandler { [weak self] in
                self?.commitBufferUnlocked()
            }
            timer.resume()
            self.commitTimer = timer
        }
    }

    // MARK: - App Switch

    private func handleAppSwitch(to newAppName: String, bundleID: String?) {
        queue.async { [weak self] in
            guard let self else { return }

            // Flush current buffer before switching
            self.commitBufferUnlocked()

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

            // Fire and forget
            Task.detached(priority: .utility) { [store] in
                await store.append(record)
            }
        }
    }

    // MARK: - Keyboard

    private func handleKeyEvent(_ event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }

            for scalar in chars.unicodeScalars {
                switch scalar {
                case "\u{8}":
                    if !self.currentBuffer.isEmpty {
                        self.currentBuffer.removeLast()
                    }
                case "\r", "\n":
                    self.commitBufferUnlocked()
                default:
                    self.currentBuffer.append(String(scalar))
                }
            }
        }
    }

    /// Must be called from queue context
    private func commitBufferUnlocked() {
        guard !currentBuffer.isEmpty else { return }

        let record = UsageRecord(
            id: UUID(),
            timestamp: Date(),
            appName: currentAppName,
            text: currentBuffer
        )
        currentBuffer = ""

        // Fire and forget - don't wait for store
        Task.detached(priority: .utility) { [store] in
            await store.append(record)
        }
    }

    // MARK: - Manual record (houmao input)

    /// Record text submitted from houmao's own input field.
    /// Can be called from any thread.
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
