import SwiftUI

@main
struct HoumaoApp: App {
    @StateObject private var mainViewModel = MainViewModel(llmClient: MockLLMClient())
    @StateObject private var historyViewModel = HistoryViewModel(store: HistoryStore())

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
    }
}

