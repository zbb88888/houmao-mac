import SwiftUI
import AppKit

@main
struct HoumaoApp: App {
    @StateObject private var mainViewModel: MainViewModel
    @StateObject private var historyViewModel: HistoryViewModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let store = HistoryStore()
        let tracker = UsageTracker(store: store)
        let vm = MainViewModel(llmClient: MockLLMClient(), usageTracker: tracker)
        _mainViewModel = StateObject(wrappedValue: vm)
        _historyViewModel = StateObject(wrappedValue: HistoryViewModel(store: store))
        AppDelegate.tracker = tracker
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(mainViewModel)
                .environmentObject(historyViewModel)
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
                    historyViewModel.load()
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.cleanup()
    }
}
