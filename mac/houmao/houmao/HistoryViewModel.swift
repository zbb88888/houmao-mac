import Foundation
import Combine
import SwiftUI

final class HistoryViewModel: ObservableObject {
    @Published var records: [UsageRecord] = []

    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
    }

    func load() {
        let loaded = store.loadAll().sorted { $0.timestamp > $1.timestamp }
        DispatchQueue.main.async {
            self.records = loaded
        }
    }

    func clearAll() {
        store.clearAll()
        DispatchQueue.main.async {
            self.records = []
        }
    }
}

