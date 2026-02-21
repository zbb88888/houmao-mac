import Foundation
import SwiftUI
import Combine
import HoumaoCore

@MainActor
final class HistoryViewModel: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    var records: [UsageRecord] = [] {
        didSet { objectWillChange.send() }
    }

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
