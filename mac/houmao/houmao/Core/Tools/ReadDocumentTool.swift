import Foundation

/// Reads the full content of a houmao result document (§7): the inline primitive
/// that bridges documents into the model's context, decoupled from how the
/// document was produced. Restricted to `~/Documents/houmao` so the agent can't
/// read arbitrary files.
struct ReadDocumentTool: AgentTool {
    let name = "read_document"
    let description = "Read the full content of a houmao result document by its file path (returned by a tool's job). Only paths under ~/Documents/houmao are allowed."

    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of the result document."),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    private let root: URL

    init(root: URL? = nil) {
        self.root = (root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/houmao", isDirectory: true)).standardizedFileURL
    }

    func invoke(arguments: JSONValue) async throws -> String {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return "error: missing required argument \"path\"."
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            return "error: path must be under \(root.path)."
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return "error: cannot read document at \(path)."
        }
        return text
    }
}
