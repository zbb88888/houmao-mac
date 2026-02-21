import SwiftUI
import AppKit
import HoumaoCore

@main
struct HoumaoApp: App {
    @StateObject private var mainViewModel: MainViewModel
    @StateObject private var historyViewModel: HistoryViewModel

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let store = HistoryStore()
        let tracker = UsageTracker(store: store)
        let vm = MainViewModel(llmClient: MockLLMClient())
        vm.usageTracker = tracker
        _mainViewModel = StateObject(wrappedValue: vm)
        _historyViewModel = StateObject(wrappedValue: HistoryViewModel(store: store))
        AppDelegate.sharedStore = store
        AppDelegate.sharedTracker = tracker
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

            CommandMenu("Debug") {
                Button("Double-Click Option Test...") {
                    HoumaoApp.openDebugWindow()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }

    static func openDebugWindow() {
        DispatchQueue.main.async {
            let debugWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            debugWindow.title = "HotKey Debug"
            debugWindow.contentView = NSHostingView(rootView: HotKeyDebugView())
            debugWindow.center()
            debugWindow.makeKeyAndOrderFront(nil)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedStore: HistoryStore?
    static var sharedTracker: UsageTracker?
    private var hotKeyManager: GlobalHotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        hotKeyManager = GlobalHotKeyManager.shared

        // Start tracker after app launches
        AppDelegate.sharedTracker?.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("Houmao App exiting...")
    }
}
