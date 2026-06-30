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

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!

    private var hotKeyManager: GlobalHotKeyManager?
    static var tracker: UsageTracker?

    private(set) var mainPanel: FloatingPanel!
    private var settingsPanel: FloatingPanel?
    private(set) var mainViewModel: MainViewModel!
    private(set) var historyViewModel: HistoryViewModel!
    private var shortcutMonitor: Any?
    private var enterChatObserver: NSObjectProtocol?
    private var exitChatObserver: NSObjectProtocol?

    /// Standalone, resizable / full-screen-capable chat window (office-style).
    /// Distinct from the floating minimal input box; shares the view model so
    /// the chat session and mode flag stay in sync.
    private var chatWindow: NSWindow?

    /// Cross-process "activate the existing instance" notification, used to keep
    /// the app to a single running instance (process-level singleton).
    private static let activateExistingNotification = Notification.Name("cn.com.houmao.activateExisting")

    /// Token for the distributed observer the primary instance registers to react
    /// to a second launch (re-open → summon the minimal box).
    private var activateObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enforce a single running instance before any UI is created: a second
        // launch (double-click / open / open -n) pings the primary instance to
        // surface itself, then this process exits.
        guard acquireSingleInstanceLock() else { return }

        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        let store = HistoryStore()
        let tracker = UsageTracker(store: store)
        Self.tracker = tracker

        mainViewModel = MainViewModel(usageTracker: tracker)
        historyViewModel = HistoryViewModel(store: store)

        setupPanel()
        setupShortcutMonitor()
        setupChatWindowObservers()

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

    /// Open / close the standalone chat window in response to the view model
    /// entering or leaving chat mode (via `/chat` or the auto-upgrade after the
    /// 3rd one-shot turn).
    private func setupChatWindowObservers() {
        enterChatObserver = NotificationCenter.default.addObserver(
            forName: .houmaoEnterChatWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showChatWindow()
        }
        exitChatObserver = NotificationCenter.default.addObserver(
            forName: .houmaoExitChatWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hideChatWindow()
        }
    }

    /// Lazily build the standalone chat window: a standard titled window that is
    /// resizable and supports native full screen — a real office surface, not
    /// the floating input box.
    private func makeChatWindow() -> NSWindow {
        let screen = screenContainingMouse()
        let visible = screen.visibleFrame
        let width = min(1040, max(760, visible.width * 0.6))
        let height = min(760, max(480, visible.height * 0.8))
        let rect = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )

        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "猛毛 Chat"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 460)
        window.delegate = self

        let chatView = ChatView()
            .environment(mainViewModel)
            .environment(historyViewModel)
        // A standard resizable window must NOT use preferredContentSize sizing,
        // otherwise it would collapse to the content's intrinsic size and fight
        // the user's manual resize / full-screen.
        let controller = NSHostingController(rootView: chatView)
        window.contentViewController = controller
        return window
    }

    private func showChatWindow() {
        // Exactly one surface is ever visible: hide the input box and settings.
        mainPanel?.orderOut(nil)
        settingsPanel?.orderOut(nil)

        let window = chatWindow ?? makeChatWindow()
        chatWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .houmaoChatWindowDidShow, object: nil)
    }

    private func hideChatWindow() {
        chatWindow?.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    /// Closing the chat window's title-bar button leaves chat mode rather than
    /// destroying the window, so the shared view model state stays consistent.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == chatWindow else { return true }
        mainViewModel.exitChatMode()
        return false
    }

    func showMainPanel() {
        // Exactly one surface is ever visible: summoning the minimal box hides
        // the standalone chat window and the settings panel. resetInput (on
        // houmaoWindowDidShow) clears the chat-mode flag.
        if chatWindow?.isVisible == true {
            chatWindow?.orderOut(nil)
        }
        if settingsPanel?.isVisible == true {
            settingsPanel?.orderOut(nil)
        }
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
            guard let self else { return event }
            // Local key-down monitors are delivered on the main thread, so it is
            // safe to touch the main-actor view models synchronously here. Only a
            // `Bool` crosses the actor-isolation boundary (NSEvent is not Sendable).
            let swallow = MainActor.assumeIsolated { () -> Bool in
                // Require Command, but reject Control/Option (Shift is allowed).
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard mods.contains(.command),
                      !mods.contains(.control),
                      !mods.contains(.option) else { return false }

                // Match on character, with a physical keyCode fallback: when a
                // text field / IME is focused the character layer for ⌘, can be
                // mangled, which previously let the input box swallow the event.
                let chars = event.charactersIgnoringModifiers?.lowercased()
                switch (chars, event.keyCode) {
                case ("l", _):
                    self.historyViewModel.clearAll()
                    return true
                case ("b", _):
                    self.mainViewModel.panel = (self.mainViewModel.panel == .history) ? .none : .history
                    return true
                case ("w", _):
                    // 关闭当前 key window（主面板或设置面板）
                    if let keyWindow = NSApp.keyWindow as? FloatingPanel {
                        keyWindow.orderOut(nil)
                    }
                    return true
                case (",", _), (_, 43): // 43 = physical comma key
                    self.openSettings()
                    return true
                default:
                    return false
                }
            }
            return swallow ? nil : event
        }
    }

    /// 打开设置面板（FloatingPanel，可覆盖全屏应用）。
    private func openSettings() {
        // Exactly one surface is ever visible: hide the input box and chat.
        mainPanel?.orderOut(nil)
        if chatWindow?.isVisible == true {
            chatWindow?.orderOut(nil)
        }

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

    /// Acquire the process-level single-instance lock. Returns false (and asks
    /// this process to terminate) when another instance of the same bundle is
    /// already running; otherwise registers the cross-process activation
    /// listener and returns true.
    ///
    /// Pure runtime enforcement (no `LSMultipleInstancesProhibited` needed):
    /// `NSRunningApplication` alone guarantees uniqueness; the distributed
    /// notification is only the "re-open surfaces the existing instance" nicety.
    private func acquireSingleInstanceLock() -> Bool {
        // Under XCTest the app boots as the unit-test host; the lock must not
        // terminate that host (it would abort the suite), so bypass it there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "cn.com.houmao.houmao"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        guard others.isEmpty else {
            // Hand off to the already-running instance, then bow out.
            DistributedNotificationCenter.default().postNotificationName(
                Self.activateExistingNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            others.first?.activate()
            NSApp.terminate(nil)
            return false
        }

        // Primary instance: a later launch will ping us to surface the box.
        activateObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.activateExistingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSApp.activate(ignoringOtherApps: true)
            self?.showMainPanel()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.cleanup()
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = enterChatObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = exitChatObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = activateObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
