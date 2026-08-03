import Testing
@testable import houmao

struct RecentAppStackTests {
    @Test
    func commitKeepsMostRecentTwoDistinctApps() {
        var stack = RecentAppStack()
        stack.commit("A")
        stack.commit("B")
        stack.commit("C")

        #expect(stack.apps == ["C", "B"])
    }

    @Test
    func commitMovesExistingAppToTop() {
        var stack = RecentAppStack()
        stack.commit("A")
        stack.commit("B")
        stack.commit("A")

        #expect(stack.apps == ["A", "B"])
    }

    @Test
    func toggleTargetWhenCurrentIsTopReturnsSecond() {
        var stack = RecentAppStack()
        stack.commit("A")
        stack.commit("B")

        #expect(stack.toggleTarget(current: "B") == "A")
    }

    @Test
    func toggleTargetWhenCurrentIsSecondReturnsTop() {
        var stack = RecentAppStack()
        stack.commit("A")
        stack.commit("B")

        #expect(stack.toggleTarget(current: "A") == "B")
    }

    @Test
    func toggleTargetWhenCurrentNotInStackReturnsTop() {
        var stack = RecentAppStack()
        stack.commit("A")
        stack.commit("B")

        #expect(stack.toggleTarget(current: "X") == "B")
    }

    @Test
    func toggleTargetWithSingleAppReturnsNilForSameCurrent() {
        var stack = RecentAppStack()
        stack.commit("A")

        #expect(stack.toggleTarget(current: "A") == nil)
    }

    @Test
    func removeEvictsExitedApp() {
        var stack = RecentAppStack()
        stack.commit("A")
        stack.commit("B")
        stack.remove("B")

        #expect(stack.apps == ["A"])
        #expect(stack.toggleTarget(current: "C") == "A")
    }
}
