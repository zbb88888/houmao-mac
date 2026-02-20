import Foundation
import AppKit

/// 采集当前前台应用 + 键盘输入，并写入 HistoryStore。
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

        // 初始化当前前台应用
        if let front = workspace.frontmostApplication {
            currentAppName = front.localizedName ?? "Unknown"
        }

        // 监听前台应用切换
        appObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }

            self.currentAppName = app.localizedName ?? "Unknown"
        }

        // 全局键盘监听（keyDown）
        // 注意：需要辅助功能权限，如果没有权限会返回 nil
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        if keyMonitor == nil {
            print("⚠️ UsageTracker: 全局键盘监听失败，可能需要辅助功能权限")
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }

        for scalar in chars.unicodeScalars {
            switch scalar {
            case "\u{8}": // Backspace
                if !currentBuffer.isEmpty {
                    currentBuffer.removeLast()
                }
            case "\r", "\n": // 回车：认为当前 buffer 结束，写入一条记录
                commitBuffer()
            default:
                currentBuffer.append(String(scalar))
            }
        }
    }

    private func commitBuffer() {
        guard !currentBuffer.isEmpty else { return }

        // 先创建记录（此时 currentBuffer 还未清空），然后立即清空 buffer
        let record = UsageRecord(
            id: UUID(),
            timestamp: Date(),
            appName: currentAppName,
            text: currentBuffer
        )
        currentBuffer = ""

        // 文件操作移到后台线程，避免阻塞键盘事件回调
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var all = self.store.loadAll()
            all.append(record)
            self.store.saveAll(all)
        }
    }
}

