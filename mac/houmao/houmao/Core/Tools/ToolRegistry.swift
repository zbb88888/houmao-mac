import Foundation

/// Holds the agent's available tools and produces the `tools` payload sent to
/// the model. Parallel to `ActionRegistry` (pipeline `$actions`) but for
/// schema'd, model-invoked tools.
struct ToolRegistry: Sendable {
    private let tools: [String: any AgentTool]

    init(_ tools: [any AgentTool] = []) {
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    }

    func tool(named name: String) -> (any AgentTool)? { tools[name] }

    /// OpenAI-style `tools` array:
    /// `[{ type: "function", function: { name, description, parameters } }]`.
    /// Sorted by name for stable output.
    func specs() -> [JSONValue] {
        tools.values.sorted { $0.name < $1.name }.map { t in
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(t.name),
                    "description": .string(t.description),
                    "parameters": t.parametersSchema,
                ]),
            ])
        }
    }
}
