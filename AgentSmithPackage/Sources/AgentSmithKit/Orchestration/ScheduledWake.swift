import Foundation

/// A scheduled wake-up registered with an `AgentActor`. When `wakeAt` arrives, the actor
/// injects a `[System: ...]` user-role message describing the wake into its conversation
/// and runs an LLM turn so the agent can take whatever follow-up the wake's `reason` implies.
public struct ScheduledWake: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var wakeAt: Date
    /// Human-readable reason the user gave when scheduling the wake. Surfaced verbatim
    /// when the wake fires so the model knows why it was scheduled.
    public var reason: String
    /// Optional task association. When set, the wake is auto-cancelled when the task
    /// transitions to a terminal status (completed/failed) — see
    /// `OrchestrationRuntime.installTaskTerminationCleanup`.
    public var taskID: UUID?

    public init(id: UUID = UUID(), wakeAt: Date, reason: String, taskID: UUID? = nil) {
        self.id = id
        self.wakeAt = wakeAt
        self.reason = reason
        self.taskID = taskID
    }
}

/// Result of a `scheduleWake` request.
public enum ScheduleWakeOutcome: Sendable {
    case scheduled(ScheduledWake)
    /// The request was rejected (validation error, etc.).
    case error(String)
}
