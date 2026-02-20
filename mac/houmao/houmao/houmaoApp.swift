import SwiftUI
import AppKit

@main
struct HoumaoApp: App {
    @StateObject private var mainViewModel = MainViewModel(llmClient: MockLLMClient())
    @StateObject private var historyViewModel: HistoryViewModel

    // 使用 AppDelegate 来管理窗口关闭行为和后台服务初始化
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let store = HistoryStore()

        // 将同一个 store 注入到 historyViewModel 中
        _historyViewModel = StateObject(wrappedValue: HistoryViewModel(store: store))

        // 通过静态变量传递 store 给 AppDelegate
        AppDelegate.sharedStore = store
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(mainViewModel)
                .environmentObject(historyViewModel)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
    }
}

// AppDelegate 用于防止窗口关闭时退出 App，并确保后台服务持续运行
class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedStore: HistoryStore?
    private var usageTracker: UsageTracker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App 启动完成后，配置为窗口关闭后继续运行
        NSApp.setActivationPolicy(.regular)

        // 在应用启动完成后异步初始化 UsageTracker，避免阻塞主线程
        if let store = Self.sharedStore {
            DispatchQueue.main.async {
                self.usageTracker = UsageTracker(store: store)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // 窗口关闭时不退出 App，后台服务继续运行
    }

    func applicationWillTerminate(_ notification: Notification) {
        // App 真正退出时（例如用户选择 Quit），清理资源
        print("Houmao App 正在退出...")
    }
}
