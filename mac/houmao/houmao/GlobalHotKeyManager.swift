import Foundation
import AppKit

/// 使用 Carbon Event 实现双击 Option 键唤醒/隐藏主窗口。
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastOptionPressTime: TimeInterval = 0
    private let doubleClickInterval: TimeInterval = 0.4
    private var optionKeyState: Bool = false

    private init() {
        checkAccessibilityPermission()

        // 同时监听本地和全局事件
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
        let isOptionKey = event.keyCode == 58 || event.keyCode == 61
        let isOptionPressed = event.modifierFlags.contains(.option)

        guard isOptionKey else { return }

        // 检测 Option 键按下（从未按下到按下的转换）
        if isOptionPressed && !optionKeyState {
            let now = Date().timeIntervalSince1970
            let timeSinceLastPress = now - lastOptionPressTime

            if timeSinceLastPress < doubleClickInterval && timeSinceLastPress > 0.05 {
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

    private func checkAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func toggleMainWindow() {
        DispatchQueue.main.async {
            // 获取主窗口（排除设置窗口）
            let mainWindow = NSApp.windows.first { window in
                window.isVisible && window.title != "Settings"
            }

            if let window = mainWindow {
                window.orderOut(nil)
            } else {
                // 显示主窗口
                NSApp.windows.first { $0.title != "Settings" }?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // Public method to cleanup (for testing or explicit shutdown)
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
