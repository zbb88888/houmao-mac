import Foundation
import AppKit

/// Opens a web page in the user's default browser — the same `NSWorkspace.open`
/// action the PR / Issue / Mail panels trigger on double-click, exposed as a
/// tool so the agent can open a link when the user asks (e.g. "打开这个 PR").
/// The `opener` is injectable so tests don't actually launch a browser.
struct OpenURLTool: AgentTool {
    let name = "open_url"
    let description = "Open a web page (http/https URL) in the user's default browser. Use when the user asks to open a PR, issue, email link, or any web page."

    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object([
                    "type": .string("string"),
                    "description": .string("The http/https URL to open."),
                ]),
            ]),
            "required": .array([.string("url")]),
        ])
    }

    private let opener: @Sendable (URL) -> Bool

    init(opener: @escaping @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.opener = opener
    }

    func invoke(arguments: JSONValue) async throws -> String {
        guard let raw = arguments["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "error: missing required argument \"url\"."
        }
        // Only http/https so the agent can't open file:// or trigger arbitrary
        // URL-scheme handlers.
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "error: only http/https URLs are allowed."
        }
        guard opener(url) else { return "error: failed to open \(raw)." }
        return "Opened \(raw) in the browser."
    }
}
