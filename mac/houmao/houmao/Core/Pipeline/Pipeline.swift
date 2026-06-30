import Foundation

/// One stage in a pipeline expression.
enum PipelineStage: Equatable {
    /// Literal input text (a non-`$` segment), used as the data source.
    case literal(String)
    /// A reference to a named action, e.g. `$translate`.
    case action(String)
}

/// A parsed pipeline: an ordered list of stages joined by `|`.
struct Pipeline: Equatable {
    let stages: [PipelineStage]

    /// The action names referenced, in order.
    var actionNames: [String] {
        stages.compactMap { if case .action(let n) = $0 { return n } else { return nil } }
    }
}

/// Data flowing through the pipeline. Each action consumes and produces one.
struct PipelineContext: Sendable {
    /// The primary text payload passed between stages.
    var text: String
    /// Model used by LLM-backed actions (translate/summarize). May be nil for
    /// actions that don't need an LLM.
    var model: ResolvedModel?
}

/// Errors surfaced while building or running a pipeline.
enum PipelineError: LocalizedError {
    case unknownAction(String)
    case missingModel(action: String)
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .unknownAction(let name):
            return "Unknown action \"$\(name)\"."
        case .missingModel(let action):
            return "Action \"$\(action)\" needs a model. Configure a provider in Settings (⌘,)."
        case .emptyInput:
            return "Pipeline has no input text."
        }
    }
}
