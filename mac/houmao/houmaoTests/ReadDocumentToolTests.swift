import Testing
import Foundation
@testable import houmao

@Test func readDocumentReadsFileUnderRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("houmao-doc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("report.md")
    try "hello document".write(to: file, atomically: true, encoding: .utf8)

    let out = try await ReadDocumentTool(root: root).invoke(arguments: .object(["path": .string(file.path)]))
    #expect(out.contains("hello document"))
}

@Test func readDocumentRejectsPathOutsideRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("houmao-doc-\(UUID().uuidString)", isDirectory: true)
    let out = try await ReadDocumentTool(root: root).invoke(arguments: .object(["path": .string("/etc/hosts")]))
    #expect(out.contains("error"))
}

@Test func readDocumentMissingPathReturnsError() async throws {
    let out = try await ReadDocumentTool().invoke(arguments: .object([:]))
    #expect(out.contains("missing required argument"))
}
