import Testing
import Foundation
@testable import houmao

// MARK: - requestBody

@Test func requestBodyOmitsToolsWhenEmpty() {
    let body = AgentModelClient.requestBody(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])
    #expect(body["tools"] == nil)
    let msgs = body["messages"]?.arrayValue
    #expect(msgs?.count == 1)
    #expect(msgs?.first?["role"]?.stringValue == "user")
    #expect(msgs?.first?["content"]?.stringValue == "hi")
    #expect(body["stream"]?.boolValue == false)
}

@Test func requestBodyPrependsSystemPromptAndTools() {
    let tools: [JSONValue] = [.object(["type": .string("function")])]
    let body = AgentModelClient.requestBody(model: "m", systemPrompt: "be helpful", messages: [.user("hi")], tools: tools)
    let msgs = body["messages"]?.arrayValue
    #expect(msgs?.first?["role"]?.stringValue == "system")
    #expect(msgs?.first?["content"]?.stringValue == "be helpful")
    #expect(body["tools"]?.arrayValue?.count == 1)
}

@Test func requestBodyEncodesAssistantToolCallArgumentsAsString() throws {
    let asst = AgentMessage.assistant(
        AssistantTurn(toolCalls: [ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("x")]))])
    )
    let body = AgentModelClient.requestBody(model: "m", systemPrompt: "", messages: [asst], tools: [])
    let msg = body["messages"]?.arrayValue?.first
    #expect(msg?["role"]?.stringValue == "assistant")
    #expect(msg?["content"] == JSONValue.null)
    let tc = msg?["tool_calls"]?.arrayValue?.first
    #expect(tc?["id"]?.stringValue == "c1")
    #expect(tc?["type"]?.stringValue == "function")
    #expect(tc?["function"]?["name"]?.stringValue == "echo")
    // arguments must be a JSON-encoded string, not a nested object.
    let argsStr = try #require(tc?["function"]?["arguments"]?.stringValue)
    let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(argsStr.utf8))
    #expect(parsed["text"]?.stringValue == "x")
}

@Test func requestBodyEncodesToolResultMessage() {
    let body = AgentModelClient.requestBody(
        model: "m", systemPrompt: "", messages: [.toolResult(id: "c1", "result text")], tools: []
    )
    let msg = body["messages"]?.arrayValue?.first
    #expect(msg?["role"]?.stringValue == "tool")
    #expect(msg?["tool_call_id"]?.stringValue == "c1")
    #expect(msg?["content"]?.stringValue == "result text")
}

// MARK: - parseTurn

@Test func parseTurnExtractsToolCall() throws {
    let json = #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"list_pull_requests","arguments":"{\"filter\":\"authored\"}"}}]}}]}"#
    let turn = try AgentModelClient.parseTurn(Data(json.utf8))
    #expect(turn.content == nil)
    #expect(turn.toolCalls.count == 1)
    #expect(turn.toolCalls[0].id == "c1")
    #expect(turn.toolCalls[0].name == "list_pull_requests")
    #expect(turn.toolCalls[0].arguments["filter"]?.stringValue == "authored")
}

@Test func parseTurnReturnsFinalContentAndStripsThink() throws {
    let json = #"{"choices":[{"message":{"content":"<think>hmm</think>final answer"}}]}"#
    let turn = try AgentModelClient.parseTurn(Data(json.utf8))
    #expect(turn.content == "final answer")
    #expect(turn.toolCalls.isEmpty)
}
