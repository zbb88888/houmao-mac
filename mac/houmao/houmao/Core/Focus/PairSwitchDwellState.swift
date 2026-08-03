import Foundation

struct PairSwitchDwellState: Sendable {
    var stack = RecentAppStack()
    var pendingBundleID: String?
    var pendingSince: Date?

    mutating func resetPending() {
        pendingBundleID = nil
        pendingSince = nil
    }

    mutating func activated(bundleID: String, isSelfApp: Bool, now: Date) {
        resetPending()
        guard !isSelfApp else { return }
        pendingBundleID = bundleID
        pendingSince = now
    }

    mutating func commitIfDue(now: Date, threshold: TimeInterval) -> Bool {
        guard let pendingBundleID, let pendingSince else { return false }
        guard now.timeIntervalSince(pendingSince) >= threshold else { return false }
        stack.commit(pendingBundleID)
        resetPending()
        return true
    }

    func remaining(now: Date, threshold: TimeInterval) -> TimeInterval? {
        guard let pendingSince else { return nil }
        return max(0, threshold - now.timeIntervalSince(pendingSince))
    }
}
