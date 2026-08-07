import Testing
import Foundation
@testable import houmao

/// Thread-safe capture of the URLs the tool tried to open (opener is @Sendable).
private final class OpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    func record(_ u: URL) { lock.lock(); _urls.append(u); lock.unlock() }
}

@Test func openURLToolOpensHTTPSURL() async throws {
    let rec = OpenRecorder()
    let tool = OpenURLTool(opener: { rec.record($0); return true })
    let result = try await tool.invoke(arguments: .object(["url": .string("https://github.com/a/b/pull/1")]))
    #expect(rec.urls.map(\.absoluteString) == ["https://github.com/a/b/pull/1"])
    #expect(result.contains("Opened"))
}

@Test func openURLToolRejectsNonHTTPScheme() async throws {
    let rec = OpenRecorder()
    let tool = OpenURLTool(opener: { rec.record($0); return true })
    let result = try await tool.invoke(arguments: .object(["url": .string("file:///etc/passwd")]))
    #expect(rec.urls.isEmpty)
    #expect(result.hasPrefix("error:"))
}

@Test func openURLToolMissingArgument() async throws {
    let tool = OpenURLTool(opener: { _ in true })
    let result = try await tool.invoke(arguments: .object([:]))
    #expect(result.hasPrefix("error:"))
}

@Test func openURLToolReportsOpenFailure() async throws {
    let tool = OpenURLTool(opener: { _ in false })
    let result = try await tool.invoke(arguments: .object(["url": .string("https://example.com")]))
    #expect(result.hasPrefix("error:"))
}
