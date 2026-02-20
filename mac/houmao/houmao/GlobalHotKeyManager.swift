import Foundation
import AppKit
import Carbon

/// 使用 Carbon Event 实现双击 Option 键唤醒/隐藏主窗口。
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var eventMonitor: Any?
    private var lastOptionPressTime: TimeInterval = 0
    private let doubleClickInterval: TimeInterval = 0.4
    private var optionKeyState: Bool = false

    private init() {
        print("🔧 GlobalHotKeyManager 初始化中...")
        checkAccessibilityPermission()

        // 同时监听本地和全局事件
        setupLocalMonitor()
        setupGlobalMonitor()
    }

    private func setupLocalMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event, source: "LOCAL")
            return event
        }
        print("✅ 本地监听器已启动")
    }

    private func setupGlobalMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event, source: "GLOBAL")
        }

        if eventMonitor == nil {
            print("⚠️ 全局监听器启动失败，可能需要辅助功能权限")
        } else {
            print("✅ 全局监听器已启动")

            // 测试：3秒后检查是否收到过全局事件
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                print("💡 提示：如果只看到 [LOCAL] 事件而没有 [GLOBAL] 事件，")
                print("   请尝试：")
                print("   1. 完全退出应用（Cmd+Q）")
                print("   2. 在「系统设置 > 隐私与安全性 > 辅助功能」中移除并重新添加应用")
                print("   3. 重新启动应用")
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent, source: String) {
        let isOptionKey = event.keyCode == 58 || event.keyCode == 61
        let isOptionPressed = event.modifierFlags.contains(.option)

        guard isOptionKey else { return }

        print("⌨️ [\(source)] FlagsChanged: keyCode=\(event.keyCode), Option=\(isOptionPressed)")

        // 检测 Option 键按下（从未按下到按下的转换）
        if isOptionPressed && !optionKeyState {
            let now = Date().timeIntervalSince1970
            let timeSinceLastPress = now - lastOptionPressTime

            print("⏱️  时间差: \(String(format: "%.3f", timeSinceLastPress))s")

            if timeSinceLastPress < doubleClickInterval && timeSinceLastPress > 0.05 {
                print("✅ 检测到双击 Option 键！")
                NotificationCenter.default.post(name: NSNotification.Name("HotKeyTriggered"), object: nil)
                Self.toggleMainWindow()
                lastOptionPressTime = 0
            } else {
                print("📝 记录第一次按下")
                lastOptionPressTime = now
            }
            optionKeyState = true
        } else if !isOptionPressed && optionKeyState {
            print("🔓 Option 键释放")
            optionKeyState = false
        }
    }

    private func checkAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if accessEnabled {
            print("✅ 已获得辅助功能权限")
        } else {
            print("⚠️ 未获得辅助功能权限！请在系统设置中授权")
            print("   路径：系统设置 > 隐私与安全性 > 辅助功能")
        }
    }

    private static func toggleMainWindow() {
        // 确保在主线程执行窗口操作
        if Thread.isMainThread {
            performToggle()
        } else {
            DispatchQueue.main.async {
                performToggle()
            }
        }
    }

    private static func performToggle() {
        DispatchQueue.main.async {
            // 获取所有窗口
            let allWindows = NSApp.windows.filter { $0.title != "HotKey Debug" }

            print("🪟 找到 \(allWindows.count) 个窗口（排除调试窗口）")

            if let window = allWindows.first {
                // 找到窗口，切换显示状态
                print("   窗口: visible=\(window.isVisible)")
                if window.isVisible {
                    print("   → 隐藏窗口")
                    window.orderOut(nil)
                } else {
                    print("   → 显示窗口")
                    window.setIsVisible(true)
                    window.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                // 没有窗口，尝试打开新窗口
                print("   ⚠️ 未找到窗口，尝试激活应用")
                NSApp.activate(ignoringOtherApps: true)

                // 使用 URL 打开新窗口（适用于 SwiftUI WindowGroup）
                if let url = URL(string: "houmao://") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

