import Foundation
import AppKit
import HoumaoCore

/// 采集当前前台应用 + 键盘输入，并写入 HistoryStore。
@MainActor
final class UsageTracker {
    private let store: HistoryStore

    private var appObserver: Any?
    private var keyMonitor: Any?

    private var currentAppName: String = "Unknown"
    private var currentBuffer: String = ""

    init(store: HistoryStore) {
        self.store = store
        start()
    }

    deinit {
        if let obs = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func start() {
        let workspace = NSWorkspace.shared

        if let front = workspace.frontmostApplication {
            currentAppName = front.localizedName ?? "Unknown"
        }

        appObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let name = app.localizedName ?? "Unknown"
            Task { @MainActor in
                self.currentAppName = name
            }
        }

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleKeyEvent(event)
            }
        }

        if keyMonitor == nil {
            print("UsageTracker: global key monitor failed, accessibility permission may be needed")
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }

        for scalar in chars.unicodeScalars {
            switch scalar {
            case "\u{8}":
                if !currentBuffer.isEmpty { currentBuffer.removeLast() }
            case "\r", "\n":
                commitBuffer()
            default:
                currentBuffer.append(String(scalar))
            }
        }
    }

    private func commitBuffer() {
        guard !currentBuffer.isEmpty else { return }

        let record = UsageRecord(
            id: UUID(),
            timestamp: Date(),
            appName: currentAppName,
            text: currentBuffer
        )
        currentBuffer = ""

        Task {
            await store.append(record)
        }
    }
}
