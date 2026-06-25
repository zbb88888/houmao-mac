import SwiftUI
import AppKit

@main
struct HoumaoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings 面板由 AppDelegate.openSettings() 通过 FloatingPanel 管理，
        // 此处保留空 WindowGroup 满足 SwiftUI App 至少一个 Scene 的要求。
        WindowGroup { EmptyView() }
            .defaultLaunchBehavior(.suppressed)
    }
}

// MARK: - Floating Panel (accepts keyboard without activating app)

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    private var hotKeyManager: GlobalHotKeyManager?
    static var tracker: UsageTracker?

    private(set) var mainPanel: FloatingPanel!
    private var settingsPanel: FloatingPanel?
    private(set) var mainViewModel: MainViewModel!
    private(set) var historyViewModel: HistoryViewModel!
    private var shortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        let store = HistoryStore()
        let tracker = UsageTracker(store: store)
        Self.tracker = tracker

        mainViewModel = MainViewModel(usageTracker: tracker)
        historyViewModel = HistoryViewModel(store: store)

        setupPanel()
        setupShortcutMonitor()

        hotKeyManager = GlobalHotKeyManager.shared
        tracker.start()

        let selectToCopy = SelectToCopyManager.shared
        selectToCopy.refreshAuthorizationState()
    }

    private func setupPanel() {
        let panel = FloatingPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false

        let mainView = MainView()
            .environment(mainViewModel)
            .environment(historyViewModel)
        let controller = NSHostingController(rootView: mainView)
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        center(panel, on: screenContainingMouse())

        self.mainPanel = panel
    }

    func showMainPanel() {
        NotificationCenter.default.post(name: .houmaoWindowDidShow, object: nil)
        center(mainPanel, on: screenContainingMouse())
        mainPanel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.center(self.mainPanel, on: self.screenContainingMouse())
        }
    }

    private func screenContainingMouse() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func center(_ panel: NSPanel, on screen: NSScreen) {
        panel.layoutIfNeeded()
        let visibleFrame = screen.visibleFrame
        let frame = panel.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    /// 本地键盘快捷键（替代菜单 .commands，accessory app 无菜单栏）。
    private func setupShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }

            switch event.charactersIgnoringModifiers {
            case "l":
                self.historyViewModel.clearAll()
                return nil
            case "b":
                self.mainViewModel.panel = (self.mainViewModel.panel == .history) ? .none : .history
                return nil
            case "w":
                // 关闭当前 key window（主面板或设置面板）
                if let keyWindow = NSApp.keyWindow as? FloatingPanel {
                    keyWindow.orderOut(nil)
                }
                return nil
            case ",":
                self.openSettings()
                return nil
            default:
                return event
            }
        }
    }

    /// 打开设置面板（FloatingPanel，可覆盖全屏应用）。
    private func openSettings() {
        mainPanel?.orderOut(nil)

        if settingsPanel == nil {
            let panel = FloatingPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.isReleasedWhenClosed = false
            panel.title = "Settings"

            let controller = NSHostingController(rootView: SettingsView())
            controller.sizingOptions = [.preferredContentSize]
            panel.contentViewController = controller
            panel.center()

            settingsPanel = panel
        }

        settingsPanel?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.cleanup()
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
