import SwiftUI
import AppKit
import HoumaoCore

@main
struct HoumaoApp: App {
    @StateObject private var mainViewModel = MainViewModel(llmClient: MockLLMClient())
    @StateObject private var historyViewModel: HistoryViewModel

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let store = HistoryStore()
        _historyViewModel = StateObject(wrappedValue: HistoryViewModel(store: store))
        AppDelegate.sharedStore = store
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
                    mainViewModel.toggleHistoryView()
                }
                .keyboardShortcut("b", modifiers: .command)
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
    private var usageTracker: UsageTracker?
    private var hotKeyManager: GlobalHotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        hotKeyManager = GlobalHotKeyManager.shared

        if let store = Self.sharedStore {
            usageTracker = UsageTracker(store: store)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("Houmao App exiting...")
    }
}
