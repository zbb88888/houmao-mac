import Testing
import Foundation
@testable import houmao

@Test func githubRefParsesPRAndIssue() {
    #expect(AnalyzeGitHubTool.parse("https://github.com/kubeovn/kube-ovn/pull/7085")
        == GitHubRef(owner: "kubeovn", repo: "kube-ovn", number: 7085))
    #expect(AnalyzeGitHubTool.parse("https://github.com/foo/bar/issues/12")?.number == 12)
    #expect(AnalyzeGitHubTool.parse("https://example.com/x") == nil)
}

@Test func resultDocumentPathFollowsConvention() {
    let url = AgentResults.documentURL(kind: "pr", id: "kubeovn-kube-ovn-7085", root: URL(fileURLWithPath: "/tmp/r"))
    #expect(url.path == "/tmp/r/pr/kubeovn-kube-ovn-7085.md")
}

@Test @MainActor func dispatchDerivesJobForValidURL() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("houmao-test-\(UUID().uuidString)")
    let tool = AnalyzeGitHubTool(mode: "pr", jobStore: JobStore(), resultsRoot: root, run: { _, _, _ in "R" })
    let job = tool.dispatch(arguments: .object(["url": .string("https://github.com/o/r/pull/9")]))
    #expect(job?.id == "o-r-9")
    #expect(job?.kind == "pr")
    #expect(job?.documentPath.hasSuffix("/pr/o-r-9.md") == true)
}

@Test @MainActor func dispatchReturnsNilForInvalidURLThenInvokeErrors() async throws {
    let tool = AnalyzeGitHubTool(mode: "pr", jobStore: JobStore(), run: { _, _, _ in "R" })
    #expect(tool.dispatch(arguments: .object(["url": .string("nope")])) == nil)
    let out = try await tool.invoke(arguments: .object(["url": .string("nope")]))
    #expect(out.contains("无法识别"))
}

@Test @MainActor func jobStoreTracksStatus() {
    let store = JobStore()
    store.start(AgentJob(id: "j1", kind: "pr", title: "t", documentPath: "/tmp/x.md"))
    #expect(store.job("j1")?.status == .running)
    store.finish("j1", status: .succeeded)
    #expect(store.job("j1")?.status == .succeeded)
    store.finish("unknown", status: .failed) // no-op for unknown id
    #expect(store.job("unknown") == nil)
}
