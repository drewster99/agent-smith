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
}

extension AgentTool {
    /// Builds the `LLMToolDefinition` from this tool's properties.
    public var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: toolDescription,
            parameters: parameters
        )
    }
}

/// Contextual information passed to tools during execution.
public struct ToolContext: Sendable {
    public let agentID: UUID
    public let agentRole: AgentRole
    public let channel: MessageChannel
    public let taskStore: TaskStore
    /// Callback to request spawning a new Brown+Jones pair.
    public let spawnBrown: @Sendable (String, String) async -> UUID?
    /// Callback to terminate an agent by ID.
    public let terminateAgent: @Sendable (UUID) async -> Bool
    /// Emergency abort: stops all agents. Requires user interaction to restart.
    public let abort: @Sendable (String) async -> Void

    public init(
        agentID: UUID,
        agentRole: AgentRole,
        channel: MessageChannel,
        taskStore: TaskStore,
        spawnBrown: @escaping @Sendable (String, String) async -> UUID?,
        terminateAgent: @escaping @Sendable (UUID) async -> Bool,
        abort: @escaping @Sendable (String) async -> Void
    ) {
        self.agentID = agentID
        self.agentRole = agentRole
        self.channel = channel
        self.taskStore = taskStore
        self.spawnBrown = spawnBrown
        self.terminateAgent = terminateAgent
        self.abort = abort
    }
}
