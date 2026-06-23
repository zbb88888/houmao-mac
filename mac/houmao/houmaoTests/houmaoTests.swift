//
//  houmaoTests.swift
//  houmaoTests
//
//  Created by ftwhmg on 2026/2/20.
//

import Testing
import Foundation
@testable import houmao

// MARK: - CommandHistory Tests

struct CommandHistoryTests {

    @Test func addAndPrevious() {
        let history = CommandHistory()
        history.add("hello")
        history.add("world")

        #expect(history.previous() == "world")
        #expect(history.previous() == "hello")
        // At beginning, stays at first
        #expect(history.previous() == "hello")
    }

    @Test func nextAfterPrevious() {
        let history = CommandHistory()
        history.add("a")
        history.add("b")
        history.add("c")

        _ = history.previous() // c
        _ = history.previous() // b
        #expect(history.next() == "c")
        // Past end returns empty string
        #expect(history.next() == "")
    }

    @Test func previousOnEmptyReturnsNil() {
        let history = CommandHistory()
        #expect(history.previous() == nil)
        #expect(history.next() == nil)
    }

    @Test func addDeduplicates() {
        let history = CommandHistory()
        history.add("hello")
        history.add("world")
        history.add("hello")

        // "hello" should be moved to end, only 2 entries
        #expect(history.previous() == "hello")
        #expect(history.previous() == "world")
        #expect(history.previous() == "world")
    }

    @Test func addTrimsWhitespace() {
        let history = CommandHistory()
        history.add("  ")
        #expect(history.previous() == nil)

        history.add("  hello  ")
        // Stored as trimmed? No — add only trims for guard check, stores trimmed
        #expect(history.previous() == "hello")
    }

    @Test func resetIndex() {
        let history = CommandHistory()
        history.add("a")
        history.add("b")

        _ = history.previous() // b
        history.reset()
        // After reset, previous starts from end again
        #expect(history.previous() == "b")
    }

    @Test func maxCountEnforced() {
        let history = CommandHistory()
        for i in 0..<110 {
            history.add("cmd\(i)")
        }
        // Should only keep last 100
        // First entry should be cmd10 (0-9 evicted)
        var items = [String]()
        while let item = history.previous() {
            if items.last == item { break } // hit beginning
            items.append(item)
        }
        #expect(items.count == 100)
        #expect(items.first == "cmd109")
    }
}

// MARK: - Worker Mention Parsing Tests

struct WorkerParsingTests {

    @Test func parseWorkerMention() {
        // Test via submit behavior — verify worker name extraction
        // We test the internal logic indirectly through AppSettings.worker(named:)
        let settings = AppSettings.shared

        // worker(named: nil) should find worker with empty name
        // worker(named: "test") should find worker named "test"
        // With no workers configured, both return nil
        let savedWorkers = settings.workers
        defer { settings.workers = savedWorkers }

        settings.workers = []
        #expect(settings.worker(named: nil) == nil)
        #expect(settings.worker(named: "test") == nil)

        settings.workers = [
            Worker(name: "", url: "http://localhost:8080", model: "test-model"),
            Worker(name: "gpt", url: "http://api.openai.com", model: "gpt-4"),
        ]

        let defaultWorker = settings.worker(named: nil)
        #expect(defaultWorker != nil)
        #expect(defaultWorker?.name == "")
        #expect(defaultWorker?.url == "http://localhost:8080")

        let namedWorker = settings.worker(named: "gpt")
        #expect(namedWorker != nil)
        #expect(namedWorker?.name == "gpt")

        // Case-insensitive
        let upperWorker = settings.worker(named: "GPT")
        #expect(upperWorker != nil)

        // Non-existent
        #expect(settings.worker(named: "nonexistent") == nil)
    }
}

// MARK: - AiTxtClient Response Parsing Tests

struct AiTxtClientTests {

    @Test func thinkTagStripping() {
        // Test the regex logic used in AiTxtClient for stripping <think> content
        let input1 = "<think>reasoning here</think>The actual answer"
        let stripped1 = input1
            .replacingOccurrences(of: "^[\\s\\S]*</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stripped1 == "The actual answer")

        let input2 = "No thinking tags here"
        let stripped2 = input2
            .replacingOccurrences(of: "^[\\s\\S]*</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stripped2 == "No thinking tags here")

        // Multiple think blocks — only content after last </think> kept
        let input3 = "<think>first</think><think>second</think>Final answer"
        let stripped3 = input3
            .replacingOccurrences(of: "^[\\s\\S]*</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stripped3 == "Final answer")
    }
}

// MARK: - HistoryStore Tests

struct HistoryStoreTests {

    @Test func appendAndLoad() async {
        let store = HistoryStore()
        await store.clearAll()

        let record = UsageRecord(
            id: UUID(),
            timestamp: Date(),
            appName: "TestApp",
            text: "test input"
        )
        await store.append(record)

        let all = await store.loadAll()
        #expect(all.contains { $0.text == "test input" })
    }

    @Test func clearAll() async {
        let store = HistoryStore()
        let record = UsageRecord(
            id: UUID(),
            timestamp: Date(),
            appName: "TestApp",
            text: "to be cleared"
        )
        await store.append(record)
        await store.clearAll()

        let all = await store.loadAll()
        #expect(all.isEmpty)
    }
}
