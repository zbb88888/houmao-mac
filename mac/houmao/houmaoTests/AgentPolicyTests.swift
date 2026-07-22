import Testing
import Foundation
@testable import houmao

struct AgentPolicyTests {
    private func policy(enabled: Bool = true, start: Int = 0, end: Int = 0) -> AgentPolicy {
        AgentPolicy(isEnabled: enabled, intervalMinutes: 15,
                    quietStartHour: start, quietEndHour: end, maxPerPoll: 5)
    }

    private func date(hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 22; comps.hour = hour
        return Calendar.current.date(from: comps)!
    }

    @Test func disabledNeverPolls() {
        #expect(policy(enabled: false).allowsPoll(at: date(hour: 12)) == false)
    }

    @Test func quietDisabledWhenStartEqualsEnd() {
        let p = policy(start: 3, end: 3)
        #expect(p.isQuiet(at: date(hour: 3)) == false)
        #expect(p.allowsPoll(at: date(hour: 3)))
    }

    @Test func sameDayWindow() {
        let p = policy(start: 9, end: 17)
        #expect(p.isQuiet(at: date(hour: 8)) == false)
        #expect(p.isQuiet(at: date(hour: 9)))
        #expect(p.isQuiet(at: date(hour: 16)))
        #expect(p.isQuiet(at: date(hour: 17)) == false)
    }

    @Test func wrapsPastMidnight() {
        let p = policy(start: 22, end: 8)
        #expect(p.isQuiet(at: date(hour: 23)))
        #expect(p.isQuiet(at: date(hour: 2)))
        #expect(p.isQuiet(at: date(hour: 8)) == false)
        #expect(p.isQuiet(at: date(hour: 12)) == false)
        #expect(p.allowsPoll(at: date(hour: 12)))
    }
}
