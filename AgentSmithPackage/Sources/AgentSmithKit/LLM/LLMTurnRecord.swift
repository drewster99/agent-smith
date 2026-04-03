import Foundation

/// Records a single LLM request/response turn for per-turn inspection.
public struct LLMTurnRecord: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    /// New messages added to conversationHistory since the previous turn.
    public let inputDelta: [LLMMessage]
    /// The full response from the LLM.
    public let response: LLMResponse
    /// Total message count in history when this call was made (for reference).
    public let totalMessageCount: Int
    /// Snapshot of the full message array sent to the LLM for this turn.
    public let contextSnapshot: [LLMMessage]
    /// Wall-clock time for the LLM API call, in milliseconds.
    public let latencyMs: Int

    // MARK: - Model / Configuration Info

    /// The model ID used for this turn (e.g. "claude-sonnet-4-20250514", "gpt-4o").
    public let modelID: String
    /// The provider type name (e.g. "anthropic", "openAICompatible", "ollama").
    public let providerType: String
    /// Temperature setting used for this turn.
    public let temperature: Double
    /// Max output tokens configured for this turn.
    public let maxOutputTokens: Int
    /// Thinking budget configured for this turn (Anthropic only), nil if disabled.
    public let thinkingBudget: Int?
    /// Token usage reported by the provider for this turn, if available.
    public let usage: TokenUsage?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        inputDelta: [LLMMessage],
        response: LLMResponse,
        totalMessageCount: Int,
        contextSnapshot: [LLMMessage] = [],
        latencyMs: Int = 0,
        modelID: String = "",
        providerType: String = "",
        temperature: Double = 0,
        maxOutputTokens: Int = 0,
        thinkingBudget: Int? = nil,
        usage: TokenUsage? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.inputDelta = inputDelta
        self.response = response
        self.totalMessageCount = totalMessageCount
        self.contextSnapshot = contextSnapshot
        self.latencyMs = latencyMs
        self.modelID = modelID
        self.providerType = providerType
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.thinkingBudget = thinkingBudget
        self.usage = usage
    }
}
