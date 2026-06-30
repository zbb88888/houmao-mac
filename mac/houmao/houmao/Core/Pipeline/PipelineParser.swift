import Foundation

/// Parses pipeline expressions of the form:
///
///     [literal text] | $action | $action ...
///
/// Rules:
/// - Stages are separated by `|` (half-width, shell-style).
/// - A segment that is exactly `$identifier` is an action reference.
/// - Any other non-empty segment is literal input text.
/// - A string is only treated as a pipeline if it contains at least one
///   `$action` reference; otherwise `parse` returns nil and the caller falls
///   back to a normal query.
enum PipelineParser {

    /// Parse `input` into a `Pipeline`, or nil if it isn't a pipeline.
    static func parse(_ input: String) -> Pipeline? {
        let segments = input
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var stages: [PipelineStage] = []
        for segment in segments where !segment.isEmpty {
            if segment.hasPrefix("$"), isValidActionName(String(segment.dropFirst())) {
                stages.append(.action(String(segment.dropFirst())))
            } else {
                stages.append(.literal(segment))
            }
        }

        // Must contain at least one action to qualify as a pipeline.
        let hasAction = stages.contains { if case .action = $0 { return true } else { return false } }
        guard hasAction else { return nil }
        return Pipeline(stages: stages)
    }

    /// An action name is a single identifier: starts with a letter/underscore,
    /// followed by letters, digits, or underscores. This avoids treating things
    /// like `$5` or `$ foo bar` as actions.
    static func isValidActionName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
