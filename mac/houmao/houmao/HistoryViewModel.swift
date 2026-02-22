import SwiftUI
import Combine

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var records: [UsageRecord] = []

    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
    }

    func load() {
        Task {
            let loaded = await store.loadAll().sorted { $0.timestamp > $1.timestamp }
            self.records = loaded
        }
    }

    func clearAll() {
        Task {
            await store.clearAll()
            self.records = []
        }
    }
}
