import SwiftUI
import Observation

@MainActor
@Observable
final class HistoryViewModel {
    var records: [UsageRecord] = []
    var hasMore: Bool = false

    private let store: HistoryStore
    private let pageSize = 100
    private var currentOffset = 0

    init(store: HistoryStore) {
        self.store = store
    }

    func load() {
        currentOffset = 0
        Task {
            let loaded = await store.loadRecent(limit: pageSize, offset: 0)
            self.records = loaded
            let total = await store.totalCount
            self.hasMore = loaded.count < total
            self.currentOffset = loaded.count
        }
    }

    func loadMore() {
        guard hasMore else { return }
        Task {
            let more = await store.loadRecent(limit: pageSize, offset: currentOffset)
            self.records.append(contentsOf: more)
            self.currentOffset += more.count
            let total = await store.totalCount
            self.hasMore = self.currentOffset < total
        }
    }

    func clearAll() {
        Task {
            await store.clearAll()
            self.records = []
            self.hasMore = false
            self.currentOffset = 0
        }
    }
}
