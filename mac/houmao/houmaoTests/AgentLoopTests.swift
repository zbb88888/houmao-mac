import Testing
import Foundation
@testable import houmao

// MARK: - Test doubles

/// A read-only tool that echoes its `text` argument.
private struct EchoTool: AgentTool {
    let name = "echo"
    let description = "Echo the input text back."
    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("text")]),
        ])
    }
    func invoke(arguments: JSONValue) async throws -> String {
        "echo: " + (arguments["text"]?.stringValue ?? "")
    }
}

/// A mutating tool that must never auto-execute.
private struct DeleteTool: AgentTool {
    let name = "delete_thing"
    let description = "Delete a thing (mutating)."
    var parametersSchema: JSONValue { .object(["type": .string("object")]) }
    var isMutating: Bool { true }
    func invoke(arguments: JSONValue) async throws -> String { "deleted" }
}

/// Vends a scripted sequence of assistant turns and records what it saw.
private actor ScriptedModel {
    private var turns: [AssistantTurn]
    private(set) var calls = 0
    init(_ turns: [AssistantTurn]) { self.turns = turns }
    func next() -> AssistantTurn {
        calls += 1
        return turns.isEmpty ? AssistantTurn(content: "done") : turns.removeFirst()
    }
}

// MARK: - JSONValue

@Test func jsonValueRoundTrips() throws {
    let v: JSONValue = .object([
        "a": .string("x"),
        "b": .number(3),
        "c": .bool(true),
        "d": .array([.number(1), .null]),
        "e": .object(["nested": .string("y")]),
    ])
    let data = try JSONEncoder().encode(v)
    let back = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(back == v)
}

// MARK: - ToolRegistry

@Test func registryProducesFunctionSpecs() {
    let specs = ToolRegistry([EchoTool()]).specs()
    #expect(specs.count == 1)
    #expect(specs[0]["type"]?.stringValue == "function")
    #expect(specs[0]["function"]?["name"]?.stringValue == "echo")
    #expect(specs[0]["function"]?["parameters"]?["type"]?.stringValue == "object")
}

// MARK: - AgentLoop

@Test func loopExecutesReadOnlyToolThenFinishes() async throws {
    let script = ScriptedModel([
        AssistantTurn(toolCalls: [ToolCall(id: "1", name: "echo", arguments: .object(["text": .string("hi")]))]),
        AssistantTurn(content: "final answer"),
    ])
    let loop = AgentLoop(registry: ToolRegistry([EchoTool()]), model: { _, _ in await script.next() })
    let outcome = try await loop.run(transcript: [.user("say hi")])
    #expect(outcome == .finished("final answer"))
    #expect(await script.calls == 2)
}

@Test func loopPausesOnMutatingTool() async throws {
    let script = ScriptedModel([
        AssistantTurn(toolCalls: [ToolCall(id: "1", name: "delete_thing", arguments: .object([:]))]),
    ])
    let loop = AgentLoop(registry: ToolRegistry([DeleteTool()]), model: { _, _ in await script.next() })
    let outcome = try await loop.run(transcript: [.user("delete it")])
    guard case .awaitingConfirmation(let call, _) = outcome else {
        Issue.record("expected awaitingConfirmation, got \(outcome)")
        return
    }
    #expect(call.name == "delete_thing")
}

@Test func resumeAfterConfirmationFinishes() async throws {
    let script = ScriptedModel([
        AssistantTurn(toolCalls: [ToolCall(id: "1", name: "delete_thing", arguments: .object([:]))]),
        AssistantTurn(content: "done deleting"),
    ])
    let loop = AgentLoop(registry: ToolRegistry([DeleteTool()]), model: { _, _ in await script.next() })
    let first = try await loop.run(transcript: [.user("delete it")])
    guard case .awaitingConfirmation(let call, let transcript) = first else {
        Issue.record("expected awaitingConfirmation, got \(first)")
        return
    }
    let final = try await loop.resume(afterApproving: call, transcript: transcript)
    #expect(final == .finished("done deleting"))
}

@Test func unknownToolProducesErrorAndContinues() async throws {
    let script = ScriptedModel([
        AssistantTurn(toolCalls: [ToolCall(id: "1", name: "nope", arguments: .object([:]))]),
        AssistantTurn(content: "recovered"),
    ])
    let loop = AgentLoop(registry: ToolRegistry([EchoTool()]), model: { _, _ in await script.next() })
    let outcome = try await loop.run(transcript: [.user("x")])
    #expect(outcome == .finished("recovered"))
}

@Test func maxStepsReachedWhenModelNeverFinishes() async throws {
    let loop = AgentLoop(
        registry: ToolRegistry([EchoTool()]),
        model: { _, _ in
            AssistantTurn(toolCalls: [ToolCall(id: "1", name: "echo", arguments: .object(["text": .string("loop")]))])
        },
        maxSteps: 3
    )
    let outcome = try await loop.run(transcript: [.user("x")])
    #expect(outcome == .maxStepsReached)
}
