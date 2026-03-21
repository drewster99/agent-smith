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
        self.pollInterval = pollInterval
        self.maxToolCalls = maxToolCalls
        self.messageDebounceInterval = messageDebounceInterval
    }

    /// Creates a runtime tuning config from the bundled defaults representation.
    public init(from defaults: AgentTuningDefaults) {
        self.pollInterval = defaults.pollInterval
        self.maxToolCalls = defaults.maxToolCalls
        self.messageDebounceInterval = defaults.messageDebounceInterval
    }
}
