import Foundation
import AppKit

/// 使用 NSEvent 的全局监听实现一个简单的全局快捷键（Option + Space），用于唤醒 / 隐藏主窗口。
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var monitor: Any?

    private init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // keyCode 49 = space 键
            let isSpace = event.keyCode == 49
            let isOption = event.modifierFlags.contains(.option)

            if isSpace && isOption {
                Self.toggleMainWindow()
            }
        }
        
        if monitor == nil {
            print("⚠️ GlobalHotKeyManager: 全局快捷键监听失败，可能需要辅助功能权限")
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
        NSApp.activate(ignoringOtherApps: true)
        
        // 查找主窗口（如果有多个窗口，找第一个可见的）
        let windows = NSApp.windows.filter { $0.isVisible }
        guard let window = windows.first else {
            // 如果没有可见窗口，创建一个新窗口
            // SwiftUI 会自动创建 WindowGroup 的窗口
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            return
        }
        
        if window.isKeyWindow {
            // 窗口当前在前台，隐藏它
            window.orderOut(nil)
        } else {
            // 窗口不在前台，显示并置顶
            window.makeKeyAndOrderFront(nil)
        }
    }
}

