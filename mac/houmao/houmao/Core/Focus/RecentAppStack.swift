import Foundation

struct RecentAppStack: Sendable {
    private(set) var apps: [String] = []

    mutating func remove(_ bundleID: String) {
        apps.removeAll { $0 == bundleID }
    }

    mutating func commit(_ bundleID: String) {
        if let idx = apps.firstIndex(of: bundleID) {
            apps.remove(at: idx)
        }
        apps.insert(bundleID, at: 0)
        if apps.count > 2 {
            apps.removeLast(apps.count - 2)
        }
    }

    func toggleTarget(current: String) -> String? {
        guard !apps.isEmpty else { return nil }
        if apps.count == 1 {
            return apps[0] == current ? nil : apps[0]
        }
        if current == apps[0] {
            return apps[1]
        }
        if current == apps[1] {
            return apps[0]
        }
        return apps[0]
    }
}
