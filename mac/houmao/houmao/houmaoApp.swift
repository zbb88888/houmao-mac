import SwiftUI
import AppKit

@main
struct HoumaoApp: App {
    @State private var mainViewModel: MainViewModel
    @State private var historyViewModel: HistoryViewModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let store = HistoryStore()
        let tracker = UsageTracker(store: store)
        let vm = MainViewModel(usageTracker: tracker)
        _mainViewModel = State(wrappedValue: vm)
        _historyViewModel = State(wrappedValue: HistoryViewModel(store: store))
        AppDelegate.tracker = tracker
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(mainViewModel)
                .environment(historyViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }

            // Cmd+K: clear conversation
            CommandGroup(after: .textEditing) {
                Button("Clear Conversation") {
                    mainViewModel.clearConversation()
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            // Cmd+B: toggle history
            CommandGroup(after: .textEditing) {
                Button("Toggle History") {
                    mainViewModel.panel = (mainViewModel.panel == .history) ? .none : .history
                }
                .keyboardShortcut("b", modifiers: .command)
            }

            // Cmd+L: clear all history
            CommandGroup(after: .textEditing) {
                Button("Clear History") {
                    historyViewModel.clearAll()
                }
                .keyboardShortcut("l", modifiers: .command)
            }

            // Cmd+W: hide window (not quit)
            CommandGroup(replacing: .saveItem) {
                Button("Hide Window") {
                    NSApplication.shared.keyWindow?.orderOut(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }

        // Settings window
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyManager: GlobalHotKeyManager?
    static var tracker: UsageTracker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        hotKeyManager = GlobalHotKeyManager.shared
        Self.tracker?.start()

        // Select-to-copy 默认关闭，仅在用户已手动开启且权限已授予时启动。
        let selectToCopy = SelectToCopyManager.shared
        if selectToCopy.isEnabled, AXIsProcessTrusted() {
            selectToCopy.startMonitoring()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.cleanup()
    }
}
