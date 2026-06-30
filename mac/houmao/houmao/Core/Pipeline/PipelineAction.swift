import Foundation

/// A single pipeline step. Implementations are referenced by `$name` in
/// pipeline expressions and registered in an `ActionRegistry`.
protocol PipelineAction: Sendable {
    /// The identifier used to reference this action, e.g. `translate`.
    var name: String { get }
    /// Transform the incoming context into an outgoing one.
    func run(_ context: PipelineContext) async throws -> PipelineContext
}

/// Maps action names to their implementations. Lives on the main actor because
/// it is populated and queried from the UI layer.
@MainActor
final class ActionRegistry {
    private var actions: [String: any PipelineAction] = [:]

    func register(_ action: any PipelineAction) {
        actions[action.name] = action
    }

    func action(named name: String) -> (any PipelineAction)? {
        actions[name]
    }

    /// All registered action names, sorted for display.
    var registeredNames: [String] {
        actions.keys.sorted()
    }
}
