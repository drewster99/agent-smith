import Foundation

/// A tool that an agent can invoke via LLM tool calling.
public protocol AgentTool: Sendable {
    /// Unique name for this tool (must match the LLM tool definition).
    var name: String { get }

    /// Human-readable description of what the tool does.
    var toolDescription: String { get }

    /// JSON Schema parameters definition.
    var parameters: [String: AnyCodable] { get }

    /// Executes the tool with the given arguments and returns a result string.
    func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String

    /// Whether this tool should be included in the LLM's tool definitions for this turn.
    /// Default is `true`. Override to conditionally hide tools based on context.
    func isAvailable(in context: ToolAvailabilityContext) -> Bool
}

/// Contextual information for determining tool availability before an LLM call.
public struct ToolAvailabilityContext: Sendable {
    /// When the user last sent a direct message to this agent, if ever.
    public let lastDirectUserMessageAt: Date?
    /// The role of the agent whose tools are being evaluated.
    public let agentRole: AgentRole

    public init(lastDirectUserMessageAt: Date? = nil, agentRole: AgentRole) {
        self.lastDirectUserMessageAt = lastDirectUserMessageAt
        self.agentRole = agentRole
    }
}

extension AgentTool {
    /// Default: tool is always available.
    public func isAvailable(in context: ToolAvailabilityContext) -> Bool { true }

    /// Returns the description to present to the LLM for a given agent role.
    /// Defaults to `toolDescription`. Override to provide role-specific instructions.
    public func description(for role: AgentRole) -> String {
        toolDescription
    }

    /// Returns the parameters schema to present to the LLM for a given agent role.
    /// Defaults to `parameters`. Override to provide role-specific parameter descriptions.
    public func parameters(for role: AgentRole) -> [String: AnyCodable] {
        parameters
    }

    /// Builds an `LLMToolDefinition` with description and parameters tailored for the given agent role.
    public func definition(for role: AgentRole) -> LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description(for: role),
            parameters: parameters(for: role)
        )
    }
}

/// Canonical reasons used when draining pending tool requests due to system-level cancellations.
/// Both the producer (OrchestrationRuntime drain sites) and consumer (AgentActor status filtering)
/// reference these constants to avoid fragile hardcoded string matching.
public enum SystemCancellationReason: String, CaseIterable, Sendable {
    case agentTerminated = "Agent terminated"
    case agentSelfTerminated = "Agent self-terminated"
    case systemShuttingDown = "System shutting down"

    /// Pre-computed set of all raw values for O(1) membership checks.
    public static let allMessages: Set<String> = Set(allCases.map(\.rawValue))
}

/// Contextual information passed to tools during execution.
public struct ToolContext: Sendable {
    public let agentID: UUID
    public let agentRole: AgentRole
    public let channel: MessageChannel
    public let taskStore: TaskStore
    /// Callback to request spawning a new Brown+Jones pair. Returns the Brown agent's ID.
    public let spawnBrown: @Sendable () async -> UUID?
    /// Callback to terminate an agent by ID. Second parameter is the caller's agent ID.
    public let terminateAgent: @Sendable (UUID, UUID) async -> Bool
    /// Emergency abort: stops all agents. Requires user interaction to restart.
    /// Second parameter is the caller's role for attribution.
    public let abort: @Sendable (String, AgentRole?) async -> Void
    /// Resolves an agent ID to its role, used for access-control checks.
    public let agentRoleForID: @Sendable (UUID) async -> AgentRole?
    /// Resolves a role to the currently active agent's UUID, used for role-based addressing.
    public let agentIDForRole: @Sendable (AgentRole) async -> UUID?
    /// Called when the agent's run loop exits naturally (errors or self-termination).
    /// Allows the runtime to clean up subscriptions and registry entries.
    public let onSelfTerminate: @Sendable () async -> Void
    /// Called with `true` when the agent begins an LLM API call, and `false` when it completes.
    public let onProcessingStateChange: @Sendable (Bool) -> Void
    /// Schedules a deferred wake-up for the agent after the given number of seconds.
    public let scheduleFollowUp: @Sendable (TimeInterval) async -> Void

    public init(
        agentID: UUID,
        agentRole: AgentRole,
        channel: MessageChannel,
        taskStore: TaskStore,
        spawnBrown: @escaping @Sendable () async -> UUID?,
        terminateAgent: @escaping @Sendable (UUID, UUID) async -> Bool,
        abort: @escaping @Sendable (String, AgentRole?) async -> Void,
        agentRoleForID: @escaping @Sendable (UUID) async -> AgentRole?,
        agentIDForRole: @escaping @Sendable (AgentRole) async -> UUID? = { _ in nil },
        onSelfTerminate: @escaping @Sendable () async -> Void = {},
        onProcessingStateChange: @escaping @Sendable (Bool) -> Void = { _ in },
        scheduleFollowUp: @escaping @Sendable (TimeInterval) async -> Void = { _ in }
    ) {
        self.agentID = agentID
        self.agentRole = agentRole
        self.channel = channel
        self.taskStore = taskStore
        self.spawnBrown = spawnBrown
        self.terminateAgent = terminateAgent
        self.abort = abort
        self.agentRoleForID = agentRoleForID
        self.agentIDForRole = agentIDForRole
        self.onSelfTerminate = onSelfTerminate
        self.onProcessingStateChange = onProcessingStateChange
        self.scheduleFollowUp = scheduleFollowUp
    }
}
