import Foundation

/// Executes a `Pipeline` stage by stage, threading the text payload through.
@MainActor
final class PipelineRunner {
    private let registry: ActionRegistry

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// Run `pipeline`.
    /// - Parameters:
    ///   - pipeline: the parsed stages.
    ///   - fallbackInput: used as the initial text when the pipeline starts
    ///     directly with an action (no leading literal segment), e.g. clipboard
    ///     contents for `$translate | $save`.
    ///   - model: model for LLM-backed actions.
    ///   - onStage: progress callback after each action stage, with the stage
    ///     index and the current text.
    /// - Returns: the final text payload.
    func run(
        _ pipeline: Pipeline,
        fallbackInput: String,
        model: ResolvedModel?,
        onStage: (@MainActor (Int, String) -> Void)? = nil
    ) async throws -> String {
        var context = PipelineContext(text: "", model: model)
        var hasInput = false

        for (index, stage) in pipeline.stages.enumerated() {
            switch stage {
            case .literal(let text):
                context.text = text
                hasInput = true

            case .action(let name):
                if !hasInput {
                    context.text = fallbackInput
                    hasInput = true
                }
                guard let action = registry.action(named: name) else {
                    throw PipelineError.unknownAction(name)
                }
                context = try await action.run(context)
                onStage?(index, context.text)
                try Task.checkCancellation()
            }
        }

        return context.text
    }
}
