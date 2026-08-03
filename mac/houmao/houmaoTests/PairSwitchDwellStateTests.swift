import Testing
import Foundation
@testable import houmao

struct PairSwitchDwellStateTests {
    @Test
    func selfActivationClearsPending() {
        var state = PairSwitchDwellState()
        let t0 = Date(timeIntervalSince1970: 100)
        state.activated(bundleID: "com.apple.Safari", isSelfApp: false, now: t0)
        state.activated(bundleID: "cn.com.houmao.houmao", isSelfApp: true, now: t0.addingTimeInterval(2))

        #expect(state.pendingBundleID == nil)
        #expect(state.pendingSince == nil)
        #expect(state.stack.apps.isEmpty)
    }

    @Test
    func commitRequiresThreshold() {
        var state = PairSwitchDwellState()
        let t0 = Date(timeIntervalSince1970: 100)
        state.activated(bundleID: "com.apple.Safari", isSelfApp: false, now: t0)

        #expect(state.commitIfDue(now: t0.addingTimeInterval(9.9), threshold: 10) == false)
        #expect(state.stack.apps.isEmpty)
        #expect(state.commitIfDue(now: t0.addingTimeInterval(10), threshold: 10) == true)
        #expect(state.stack.apps == ["com.apple.Safari"])
    }

    @Test
    func secondActivationReplacesPendingCandidate() {
        var state = PairSwitchDwellState()
        let t0 = Date(timeIntervalSince1970: 100)
        state.activated(bundleID: "com.apple.Safari", isSelfApp: false, now: t0)
        state.activated(bundleID: "com.apple.dt.Xcode", isSelfApp: false, now: t0.addingTimeInterval(3))

        #expect(state.pendingBundleID == "com.apple.dt.Xcode")
        #expect(state.commitIfDue(now: t0.addingTimeInterval(12), threshold: 10) == false)
        #expect(state.commitIfDue(now: t0.addingTimeInterval(13), threshold: 10) == true)
        #expect(state.stack.apps == ["com.apple.dt.Xcode"])
    }
}
