import SwiftUI
import AppKit
import UserNotifications
import os.log

private let notifyLog = Logger(subsystem: "com.houmao", category: "Notifications")

@main
struct HoumaoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Windows (chat / minimal box) are AppKit-driven via AppDelegate; the
        // empty, suppressed WindowGroup only satisfies SwiftUI's "≥ 1 scene"
        // requirement. The Settings scene gives the standard "Settings…" app-menu
        // item (⌘,) for free, at the conventional macOS location — no manual
        // NSMenuItem wiring (which SwiftUI would rebuild away).
        WindowGroup { EmptyView() }
            .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Floating Panel (accepts keyboard without activating app)

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate!

    private var hotKeyManager: GlobalHotKeyManager?
    static var tracker: UsageTracker?

    private(set) var mainPanel: FloatingPanel!
    /// Held for the whole process lifetime; closing it drops the single-instance flock.
    private var lockFileDescriptor: Int32 = -1
    private(set) var mainViewModel: MainViewModel!
    private(set) var historyViewModel: HistoryViewModel!
    private(set) var mailViewModel: MailViewModel!
    private var shortcutMonitor: Any?
    private var enterChatObserver: NSObjectProtocol?
    private var exitChatObserver: NSObjectProtocol?
    private var chatStatusObserver: NSObjectProtocol?
    private var enterMailObserver: NSObjectProtocol?
    private var exitMailObserver: NSObjectProtocol?
    private var openMailDetailObserver: NSObjectProtocol?
    private var closeMailDetailObserver: NSObjectProtocol?

    /// Standalone, resizable / full-screen-capable chat window (office-style).
    /// Distinct from the floating minimal input box; shares the view model so
    /// the chat session stays in sync.
    private var chatWindow: NSWindow?
    /// Standalone Gmail cleanup window (`/mail`), same shell as the chat window.
    private var mailWindow: NSWindow?
    /// Standalone message-detail window opened from the mail list (standard large
    /// window, not an in-place sheet).
    private var mailDetailWindow: NSWindow?

    /// One-shot observers used to defer hiding a full-screen window until its
    /// exit-full-screen transition completes, keyed by window (a full-screen
    /// `orderOut` otherwise leaves an empty black Space). Shared by all windows.
    private var fsExitObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

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
        NSApp.setActivationPolicy(.regular)

        setupNotifications()

        let store = HistoryStore()
        let tracker = UsageTracker(store: store)
        Self.tracker = tracker

        mainViewModel = MainViewModel(usageTracker: tracker)
        historyViewModel = HistoryViewModel(store: store)
        mailViewModel = MailViewModel()

        setupPanel()
        setupShortcutMonitor()
        setupChatWindowObservers()
        setupMailWindowObservers()

        hotKeyManager = GlobalHotKeyManager.shared
        tracker.start()

        let selectToCopy = SelectToCopyManager.shared
        selectToCopy.refreshAuthorizationState()

        // The chat window is the app's main UI window; present it on launch.
        showChatWindow()
    }

    // MARK: - Local notifications (long-running task completion)

    /// Register as the notification-center delegate and request permission to
    /// post local notifications, so long-running tasks (e.g. the `/pr` six-stage
    /// review) can pop a completion banner when the window isn't focused.
    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                notifyLog.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                notifyLog.notice("notification authorization granted=\(granted, privacy: .public)")
            }
        }
    }

    /// Post a "task finished" banner. Safe to call from any context; delivery is
    /// best-effort (silently no-ops if the user denied notification permission).
    func notifyTaskDone(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifyLog.error("deliver notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Show banners even while the app is frontmost (the chat window usually is).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
        // Disable safe-area tracking: combined with `.fullSizeContentView` and a
        // dynamic content height it otherwise feeds an infinite Update-Constraints
        // pass that crashes the panel (NSGenericException). A borderless floating
        // panel has no visible safe-area inset, so this is purely a loop breaker.
        controller.safeAreaRegions = []
        panel.contentViewController = controller
        center(panel, on: screenContainingMouse())

        self.mainPanel = panel
    }

    /// Show / hide the standalone chat window in response to the
    /// `.houmaoEnterChatWindow` / `.houmaoExitChatWindow` notifications the view
    /// model posts (from `/chat`, the auto-upgrade, or the in-view exit button).
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
        chatStatusObserver = NotificationCenter.default.addObserver(
            forName: .houmaoChatStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let status = (note.object as? String) ?? "houmao"
            self?.chatWindow?.title = status.isEmpty ? "houmao" : status
        }
    }

    /// Lazily build the standalone chat window: a standard titled window that is
    /// resizable and supports native full screen — a real office surface, not
    /// the floating input box.
    private func makeChatWindow() -> NSWindow {
        // Same centered golden-ratio proportion as the mail windows.
        let rect = centeredGoldenRect(on: screenContainingMouse())

        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "houmao"
        window.titlebarAppearsTransparent = true
        // Title is used as a status line (topic / tool progress), so keep it visible.
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 460)
        window.delegate = self

        let chatView = ChatView()
            .environment(mainViewModel)
        // A standard resizable window must NOT use preferredContentSize sizing,
        // otherwise it would collapse to the content's intrinsic size and fight
        // the user's manual resize / full-screen.
        let controller = NSHostingController(rootView: chatView)
        window.contentViewController = controller
        return window
    }

    private func showChatWindow() {
        // The chat window is an independent singleton; showing it leaves the
        // input box as-is.
        let window = chatWindow ?? makeChatWindow()
        chatWindow = window

        // Open at the same centered golden-ratio size as the mail window every
        // time (unless the user has taken it full screen), so both surfaces match.
        if !window.styleMask.contains(.fullScreen) {
            window.setFrame(centeredGoldenRect(on: screenContainingMouse()), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .houmaoChatWindowDidShow, object: nil)
    }

    private func hideChatWindow() {
        guard let window = chatWindow else { return }
        hideWindowSafely(window)
    }

    /// Hide a window without leaving an empty black full-screen Space: if it is
    /// full screen, exit full screen first and `orderOut` once the transition
    /// completes; otherwise hide immediately. Shared by the chat and mail windows.
    private func hideWindowSafely(_ window: NSWindow) {
        guard window.styleMask.contains(.fullScreen) else {
            window.orderOut(nil)
            return
        }
        let key = ObjectIdentifier(window)
        if let obs = fsExitObservers[key] {
            NotificationCenter.default.removeObserver(obs)
        }
        fsExitObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            window.orderOut(nil)
            guard let self, let obs = self.fsExitObservers[key] else { return }
            NotificationCenter.default.removeObserver(obs)
            self.fsExitObservers[key] = nil
        }
        window.toggleFullScreen(nil)
    }

    // MARK: NSWindowDelegate

    /// The title-bar close button hides the chat window instead of destroying it
    /// (this is a standard, always-resident app), and clears the shared
    /// view-model input state.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == mailWindow {
            hideMailWindow()
            return false
        }
        if sender == mailDetailWindow {
            hideWindowSafely(sender)
            mailViewModel.closeDetail()
            return false
        }
        guard sender == chatWindow else { return true }
        hideChatWindow()
        mainViewModel.exitChatMode()
        return false
    }

    // MARK: Mail window (`/mail`)

    private func setupMailWindowObservers() {
        enterMailObserver = NotificationCenter.default.addObserver(
            forName: .houmaoEnterMailWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showMailWindow()
        }
        exitMailObserver = NotificationCenter.default.addObserver(
            forName: .houmaoExitMailWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hideMailWindow()
        }
        openMailDetailObserver = NotificationCenter.default.addObserver(
            forName: .houmaoOpenMailDetail, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showMailDetailWindow()
        }
        closeMailDetailObserver = NotificationCenter.default.addObserver(
            forName: .houmaoCloseMailDetail, object: nil, queue: .main
        ) { [weak self] _ in
            // Route through the standard close path (windowShouldClose) so it
            // hides safely and resets detail state, exactly like the ✕ button.
            self?.mailDetailWindow?.performClose(nil)
        }
    }

    /// Hide the mail window. Uses `hideWindowSafely` so a full-screen close does
    /// not leave an empty black Space.
    private func hideMailWindow() {
        guard let window = mailWindow else { return }
        hideWindowSafely(window)
    }

    private func makeMailWindow() -> NSWindow {
        let rect = centeredGoldenRect(on: screenContainingMouse())
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "mail"
        window.titlebarAppearsTransparent = true
        // Force light appearance so the title renders black over the light green
        // theme (dark mode would draw it white).
        window.appearance = NSAppearance(named: .aqua)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.delegate = self

        let mailView = MailView().environment(mailViewModel)
        window.contentViewController = NSHostingController(rootView: mailView)
        return window
    }

    /// A window rect centered on `screen`, sized to the golden ratio (0.618) of
    /// the usable screen in each dimension.
    private func centeredGoldenRect(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let golden = 0.618
        let width = visible.width * golden
        let height = visible.height * golden
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func showMailWindow() {
        let window = mailWindow ?? makeMailWindow()
        mailWindow = window
        // Open centered at the golden-ratio size every time (unless the user has
        // taken it full screen), matching the chat window's centered shell.
        if !window.styleMask.contains(.fullScreen) {
            window.setFrame(centeredGoldenRect(on: screenContainingMouse()), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Standard large detail window (mirrors the chat window's shell), shared as
    /// a singleton and reused for whichever message the user opens.
    private func makeMailDetailWindow() -> NSWindow {
        let visible = screenContainingMouse().visibleFrame
        let width = min(1400, max(820, visible.width * 0.8))
        let height = min(1000, max(560, visible.height * 0.8))
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
        window.title = "邮件详情"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.delegate = self

        let detailView = MailDetailView().environment(mailViewModel)
        window.contentViewController = NSHostingController(rootView: detailView)
        return window
    }

    private func showMailDetailWindow() {
        let window = mailDetailWindow ?? makeMailDetailWindow()
        mailDetailWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showMainPanel() {
        // Each surface is an independent singleton; summoning the minimal box
        // leaves the chat window as-is.
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

    /// 应用内键盘快捷键：⌘L 清空历史、⌘B 切换历史面板、⌘W 关闭当前面板。
    /// （⌘, 打开设置由标准应用菜单项处理，见 setupAppMenu。）
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
                default:
                    return false
                }
            }
            return swallow ? nil : event
        }
    }

    /// Acquire the process-level single-instance lock via an exclusive advisory
    /// `flock` on a per-user lockfile. Returns false (and terminates this
    /// process) when another instance already holds the lock; otherwise keeps
    /// the fd open for the process lifetime, registers the cross-process
    /// activation listener, and returns true.
    private func acquireSingleInstanceLock() -> Bool {
        // Under XCTest the app boots as the unit-test host; the lock must not
        // terminate that host (it would abort the suite), so bypass it there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        // Atomic, kernel-level mutex: the first instance grabs an exclusive
        // advisory lock on a per-user lockfile; a concurrent second launch gets
        // EWOULDBLOCK immediately, so there is no check-then-act race like the
        // old NSRunningApplication scan. The lock is released automatically when
        // the fd closes on normal exit or crash, so there is no stale-lock file
        // to clean up. The fd is held for the whole process lifetime via
        // `lockFileDescriptor` — closing it would drop the lock.
        let bundleID = Bundle.main.bundleIdentifier ?? "cn.com.houmao.houmao"
        let lockPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(bundleID).singleton.lock")
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // Lockfile could not be opened (unexpected). Degrade to allowing the
            // launch rather than blocking the app entirely.
            return true
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Another instance already holds the lock: ping it to surface the
            // box, drop our fd, and bow out.
            close(fd)
            DistributedNotificationCenter.default().postNotificationName(
                Self.activateExistingNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            NSApp.terminate(nil)
            return false
        }

        // Primary instance: keep the fd open for the process lifetime and let a
        // later launch ping us to surface the box.
        lockFileDescriptor = fd
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Standard-app behavior: clicking the Dock icon (or otherwise reopening)
        // brings the chat window — the app's main UI — back to the front.
        if !flag {
            showChatWindow()
        }
        return true
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
        if let observer = chatStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = activateObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
