import Cocoa
import ApplicationServices
import os.log
import Carbon.HIToolbox

private let selectLog = Logger(subsystem: "com.houmao", category: "SelectToCopy")

/// 划选即复制：监听全局鼠标拖拽，检测到选取后模拟 Cmd+C 将选中文本写入剪贴板。
///
/// ## 实现策略（参考 iboob / Maccy 等开源项目）
/// 1. 全局监听 mouseDown/mouseUp，通过拖拽距离区分点击和选取。
/// 2. 保存剪贴板当前内容。
/// 3. 向前台 App 的 PID 定向发送 CGEvent 模拟 Cmd+C。
/// 4. 轮询剪贴板 changeCount 判断是否有新内容写入（最多 500ms）。
/// 5. 如果剪贴板未变化，恢复之前保存的内容。
final class SelectToCopyManager: NSObject {
    static let shared = SelectToCopyManager()

    // MARK: - 事件监听器

    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?

    // MARK: - 拖拽状态

    private var mouseDownPoint: CGPoint?

    // MARK: - 配置常量

    /// 拖拽距离阈值（屏幕坐标点）。
    private let dragThreshold: CGFloat = 5.0

    /// mouseUp 后等待 App 完成选区更新的延迟。
    private let preSimulateDelay: TimeInterval = 0.05

    /// 轮询剪贴板的间隔。
    private let pollInterval: TimeInterval = 0.05

    /// 轮询剪贴板的最大次数（50ms × 10 = 500ms 超时）。
    private let maxPollAttempts = 10

    // MARK: - 后台队列

    private let copyQueue = DispatchQueue(
        label: "com.houmao.selectToCopy.copy",
        qos: .userInitiated
    )

    // MARK: - UserDefaults 键

    private static let enabledKey = "selectToCopyEnabled"

    // MARK: - 日志

    private let tag = "[SelectToCopy]"

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
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue {
                if AXIsProcessTrusted() {
                    startMonitoring()
                } else {
                    log("辅助功能权限未授予，打开系统设置")
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                    startPermissionPolling()
                }
            } else {
                stopMonitoring()
                permissionPollTimer?.invalidate()
                permissionPollTimer = nil
            }
        }
    }

    /// 轮询 AXIsProcessTrusted()，授权后自动启动监听。
    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.permissionPollTimer = nil
                self?.startMonitoring()
                self?.log("辅助功能权限已授予，监听已自动启动")
            }
        }
    }

    func startMonitoring() {
        guard isEnabled else {
            log("功能已禁用，不启动监听")
            return
        }
        guard mouseDownMonitor == nil else {
            log("监听已在运行，跳过重复启动")
            return
        }

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] _ in
            self?.mouseDownPoint = NSEvent.mouseLocation
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp
        ) { [weak self] _ in
            self?.handleMouseUp()
        }

        log("监听已启动")
    }

    func stopMonitoring() {
        [mouseDownMonitor, mouseUpMonitor].forEach { monitor in
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
        mouseDownMonitor = nil
        mouseUpMonitor = nil
        mouseDownPoint = nil
        log("监听已停止")
    }

    // MARK: - 事件处理

    private func handleMouseUp() {
        guard let origin = mouseDownPoint else { return }
        mouseDownPoint = nil

        let current = NSEvent.mouseLocation
        let distance = hypot(current.x - origin.x, current.y - origin.y)
        guard distance >= dragThreshold else { return }

        // 捕获前台 App 的 PID（必须在主线程获取）。
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName ?? frontApp.bundleIdentifier ?? "未知"

        log("检测到划选，距离 \(String(format: "%.1f", distance))pt，应用: \(appName) (pid=\(pid))")

        // 保存剪贴板状态。
        let pb = NSPasteboard.general
        let changeCountBefore = pb.changeCount
        let savedItems = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        copyQueue.asyncAfter(deadline: .now() + self.preSimulateDelay) { [weak self] in
            guard let self else { return }
            self.performCopyAndCheck(pid: pid, appName: appName,
                                     changeCountBefore: changeCountBefore,
                                     savedItems: savedItems)
        }
    }

    // MARK: - 复制 + 轮询检查

    private func performCopyAndCheck(pid: pid_t, appName: String,
                                      changeCountBefore: Int,
                                      savedItems: [[NSPasteboard.PasteboardType: Data]]) {
        // 策略 1：向目标 PID 定向发送 Cmd+C（最精准）。
        if !simulateCmdC(toPid: pid) {
            // 策略 2：全局 post（兜底）。
            if !simulateCmdC(toPid: nil) {
                log("模拟 Cmd+C 完全失败")
                return
            }
        }

        // 轮询剪贴板，等待 App 写入。
        let pb = NSPasteboard.general
        for attempt in 1...maxPollAttempts {
            Thread.sleep(forTimeInterval: pollInterval)
            if pb.changeCount != changeCountBefore {
                let copied = pb.string(forType: .string) ?? ""
                if !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectLog.info("\(self.tag) ✓ 已复制 \(copied.count) 字符（\(appName)，第 \(attempt) 次轮询）")
                    return
                }
            }
        }

        // 超时：剪贴板未变化，恢复之前保存的内容。
        log("轮询 \(maxPollAttempts) 次后剪贴板未变化，恢复原始内容")
        restorePasteboard(savedItems)
    }

    // MARK: - 模拟 Cmd+C

    /// 模拟 Cmd+C 按键事件。
    /// - Parameter toPid: 目标进程 PID。nil 表示全局 post。
    /// - Returns: 事件是否成功创建并发送。
    private func simulateCmdC(toPid pid: pid_t?) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source,
                                     virtualKey: CGKeyCode(kVK_ANSI_C),
                                     keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                   virtualKey: CGKeyCode(kVK_ANSI_C),
                                   keyDown: false) else {
            log("CGEvent 创建失败")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        if let pid {
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
            log("Cmd+C 已发送至 pid=\(pid)")
        } else {
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
            log("Cmd+C 已全局发送 (cgSessionEventTap)")
        }

        return true
    }

    // MARK: - 剪贴板恢复

    /// 恢复之前保存的剪贴板内容。
    private func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        guard !items.isEmpty else { return }
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            for itemData in items {
                let item = NSPasteboardItem()
                for (type, data) in itemData {
                    item.setData(data, forType: type)
                }
                pb.writeObjects([item])
            }
        }
    }

    // MARK: - 辅助方法

    private func log(_ message: String) {
        selectLog.info("\(self.tag) \(message)")
    }
}
