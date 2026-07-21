import Cocoa
import ApplicationServices
import os.log
import Carbon.HIToolbox

private let pasteLog = Logger(subsystem: "com.houmao", category: "MiddleClickPaste")

extension Notification.Name {
    static let houmaoMiddleClickPasteAuthorizationDidChange = Notification.Name("houmaoMiddleClickPasteAuthorizationDidChange")
}

/// 鼠标中键（全局）粘贴：监听全局中键点击，向前台 App 模拟 Cmd+V。
///
/// 与 `SelectToCopyManager`（划选即复制）配对，复刻 Linux 主选区（primary
/// selection）体验：划选自动复制到剪贴板，中键点击即把剪贴板内容粘贴到落点。
///
/// ## 实现策略
/// 1. 全局监听 `.otherMouseDown`，仅处理中键（buttonNumber == 2）。
/// 2. 稍作延迟等前台 App 抢焦完成后，在 HID 层注入 Cmd+V。
/// 3. 使用 `cghidEventTap` 注入（等效真实键盘），兼容 Electron 等多进程应用。
///
/// ## 已知差异（相对 Linux 主选区）
/// macOS 的 AppKit **不会**在中键点击时移动插入点，因此粘贴落在
/// 目标 App 当前的光标/选区处，而非鼠标点击的具体位置。
final class MiddleClickPasteManager: NSObject {
    static let shared = MiddleClickPasteManager()

    // MARK: - 事件监听器

    private var mouseDownMonitor: Any?

    // MARK: - 配置常量

    /// 等待中键点击把目标 App 切到前台并抢焦完成，再注入 Cmd+V 的延迟。
    private let prePasteDelay: TimeInterval = 0.03

    /// macOS 中键的 buttonNumber（0=左，1=右，2=中）。
    private let middleButtonNumber = 2

    // MARK: - UserDefaults 键

    private static let enabledKey = "middleClickPasteEnabled"

    // MARK: - 日志

    private let tag = "[MiddleClickPaste]"

    // MARK: - 生命周期

    override private init() {
        super.init()
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
        }
    }

    // MARK: - 公开接口

    /// 辅助功能权限轮询 Timer。
    private var permissionPollTimer: Timer?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) && AXIsProcessTrusted() }
        set {
            if newValue {
                if AXIsProcessTrusted() {
                    UserDefaults.standard.set(true, forKey: Self.enabledKey)
                    startMonitoring()
                } else {
                    // 未授权：不持久化启用状态，仅打开系统设置并轮询本次授权结果。
                    UserDefaults.standard.set(false, forKey: Self.enabledKey)
                    log("辅助功能权限未授予，打开系统设置，等待授权")
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                    startPermissionPolling()
                }
            } else {
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
                stopMonitoring()
                permissionPollTimer?.invalidate()
                permissionPollTimer = nil
            }
        }
    }

    func refreshAuthorizationState() {
        guard isEnabled else {
            stopMonitoring()
            return
        }

        if AXIsProcessTrusted() {
            startMonitoring()
        } else {
            startPermissionPolling()
        }
    }

    /// 轮询 AXIsProcessTrusted()，授权后自动设为 true 并启动监听。
    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.permissionPollTimer = nil
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                self?.startMonitoring()
                NotificationCenter.default.post(name: .houmaoMiddleClickPasteAuthorizationDidChange, object: nil)
                self?.log("辅助功能权限已授予，监听已自动启动")
            }
        }
    }

    func startMonitoring() {
        guard isEnabled else {
            log("功能已禁用，不启动监听")
            return
        }
        guard AXIsProcessTrusted() else {
            log("辅助功能权限未授予，不启动监听")
            startPermissionPolling()
            return
        }
        guard mouseDownMonitor == nil else {
            log("监听已在运行，跳过重复启动")
            return
        }

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .otherMouseDown
        ) { [weak self] event in
            guard let self, event.buttonNumber == self.middleButtonNumber else { return }
            self.handleMiddleClick()
        }

        log("监听已启动")
    }

    func stopMonitoring() {
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        mouseDownMonitor = nil
        log("监听已停止")
    }

    // MARK: - 事件处理

    private func handleMiddleClick() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? frontApp.bundleIdentifier ?? "未知"
        log("检测到中键点击，粘贴到应用: \(appName)")

        // 稍作延迟，让目标 App 完成切前台/抢焦，再注入 Cmd+V。
        DispatchQueue.main.asyncAfter(deadline: .now() + prePasteDelay) { [weak self] in
            self?.simulateCmdV()
        }
    }

    // MARK: - 模拟 Cmd+V

    private func simulateCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: CGKeyCode(kVK_ANSI_V),
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_ANSI_V),
                                  keyDown: false) else {
            log("CGEvent 创建失败")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        log("Cmd+V 已全局发送 (cghidEventTap)")
    }

    // MARK: - 辅助方法

    private func log(_ message: String) {
        pasteLog.info("\(self.tag) \(message)")
    }
}
