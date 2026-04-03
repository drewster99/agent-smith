import Foundation

/// A single LLM API call's token usage, persisted for analytics.
public struct UsageRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let agentRole: AgentRole
    /// The task this call was made in service of, if any.
    public let taskID: UUID?
    /// Raw model ID (e.g. "claude-sonnet-4-20250514", "mistral-large-latest").
    public let modelID: String
    /// Provider type key (e.g. "anthropic", "openAICompatible", "ollama").
    public let providerType: String
    /// The ModelConfiguration UUID this call used, if known.
    public let configurationID: UUID?
    /// Input (prompt + context) tokens.
    public let inputTokens: Int
    /// Output (completion) tokens.
    public let outputTokens: Int
    /// Anthropic: tokens served from prompt cache. 0 for other providers.
    public let cacheReadTokens: Int
    /// Anthropic: tokens written to prompt cache. 0 for other providers.
    public let cacheWriteTokens: Int
    /// Wall-clock latency in milliseconds.
    public let latencyMs: Int
    /// If non-nil, a context reset occurred just before this turn.
    /// The value is the input token count from the last turn before pruning.
    public let preResetInputTokens: Int?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        agentRole: AgentRole,
        taskID: UUID?,
        modelID: String,
        providerType: String,
        configurationID: UUID?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        latencyMs: Int,
        preResetInputTokens: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.agentRole = agentRole
        self.taskID = taskID
        self.modelID = modelID
        self.providerType = providerType
        self.configurationID = configurationID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.latencyMs = latencyMs
        self.preResetInputTokens = preResetInputTokens
    }
}
