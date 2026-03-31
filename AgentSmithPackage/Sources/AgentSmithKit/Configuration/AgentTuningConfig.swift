import Foundation

/// Runtime-passable tuning configuration for an agent's run loop.
///
/// Replaces hardcoded values in `OrchestrationRuntime` so they can be
/// driven by the bundled defaults JSON or user-configured settings.
public struct AgentTuningConfig: Sendable {
    /// Seconds between idle poll cycles.
    public var pollInterval: TimeInterval
    /// Maximum tool calls the agent will execute per LLM response.
    public var maxToolCalls: Int
    /// Seconds of channel silence required before processing batched messages.
    public var messageDebounceInterval: TimeInterval

    public init(
        pollInterval: TimeInterval = 5,
        maxToolCalls: Int = 100,
        messageDebounceInterval: TimeInterval = 1
    ) {
        self.pollInterval = max(pollInterval, 0.5)
        self.maxToolCalls = max(maxToolCalls, 1)
        self.messageDebounceInterval = max(messageDebounceInterval, 0)
    }

    /// Creates a runtime tuning config from the bundled defaults representation.
    public init(from defaults: AgentTuningDefaults) {
        self.init(
            pollInterval: defaults.pollInterval,
            maxToolCalls: defaults.maxToolCalls,
            messageDebounceInterval: defaults.messageDebounceInterval
        )
    }
}
