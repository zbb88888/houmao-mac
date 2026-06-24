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

// MARK: - Model Resolution Tests

struct ModelResolutionTests {

    @Test func resolveModel() {
        let settings = AppSettings.shared

        let savedProviders = settings.providers
        defer { settings.providers = savedProviders }

        settings.providers = []
        #expect(settings.resolveModel(named: nil) == nil)
        #expect(settings.resolveModel(named: "gpt-4o") == nil)

        settings.providers = [
            Provider(name: "Local", apiHost: "http://localhost:8080", models: ["test-model"]),
            Provider(name: "OpenAI", apiHost: "https://api.openai.com", apiKey: "sk-xxx", models: ["gpt-4o", "gpt-4o-mini"]),
        ]

        // Default: first provider's first model
        let defaultModel = settings.resolveModel(named: nil)
        #expect(defaultModel != nil)
        #expect(defaultModel?.model == "test-model")
        #expect(defaultModel?.provider.name == "Local")

        // Find by provider alias (name)
        let byAlias = settings.resolveModel(named: "OpenAI")
        #expect(byAlias != nil)
        #expect(byAlias?.model == "gpt-4o")
        #expect(byAlias?.provider.name == "OpenAI")

        // Provider alias is case-insensitive
        let byAliasUpper = settings.resolveModel(named: "openai")
        #expect(byAliasUpper != nil)
        #expect(byAliasUpper?.provider.name == "OpenAI")

        // Find by model name (fallback)
        let gpt4oMini = settings.resolveModel(named: "gpt-4o-mini")
        #expect(gpt4oMini != nil)
        #expect(gpt4oMini?.provider.name == "OpenAI")

        // Case-insensitive model match
        let upper = settings.resolveModel(named: "GPT-4O")
        #expect(upper != nil)

        // Non-existent
        #expect(settings.resolveModel(named: "nonexistent") == nil)
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
