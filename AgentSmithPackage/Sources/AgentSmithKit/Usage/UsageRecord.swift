import Foundation
import SwiftLLMKit

/// A single LLM API call's token usage, persisted for analytics.
public struct UsageRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let agentRole: AgentRole
    /// The task this call was made in service of, if any.
    public let taskID: UUID?
    /// Raw model ID (e.g. "claude-sonnet-4-20250514", "mistral-large-latest").
    public let modelID: String
    /// Provider type key (e.g. "anthropic", "openAICompatible", "ollama"). Identifies
    /// the wire protocol family — too coarse to disambiguate two providers using the
    /// same protocol (e.g. Anthropic-direct vs. OpenRouter both use "anthropic").
    public let providerType: String
    /// Stable provider identifier (e.g. "anthropic", "openrouter", a UUID for a custom
    /// provider). Together with `modelID` this is the lookup key into `ModelInfo` for
    /// pricing — `providerType` alone is not specific enough. Optional only because
    /// records persisted before this field was added decode with `nil`; all new records
    /// populate it. Also available as `configuration?.providerID` — kept top-level for
    /// fast filtering without decoding the nested struct.
    public let providerID: String?
    /// Full snapshot of the ModelConfiguration used for this call, captured at write
    /// time. Preserves settings like context window size, temperature, max tokens,
    /// thinking budget, and extended cache TTL — all of which affect interpretation
    /// of the usage numbers. Immutable historical truth: even if the source config
    /// is later deleted or edited, this embedded copy stays accurate. Optional only
    /// because records persisted before this field was added decode with `nil`; the
    /// startup migration backfills it where the lookup is unambiguous.
    public let configuration: ModelConfiguration?
    /// Vestigial legacy field preserved so the one-shot migration can look up the
    /// originating ModelConfiguration by UUID for records persisted before the full
    /// `configuration` snapshot was captured. New records write both — this field
    /// equals `configuration?.id`. Remove this and the migration together after May
    /// 9 2026.
    public let configurationID: UUID?
    /// Input (prompt + context) tokens.
    public let inputTokens: Int
    /// Output (completion) tokens.
    public let outputTokens: Int
    /// Anthropic: tokens served from prompt cache. 0 for other providers.
    public let cacheReadTokens: Int
    /// Anthropic: tokens written to prompt cache. 0 for other providers.
    public let cacheWriteTokens: Int
    /// Wall-clock latency for the LLM API call in milliseconds.
    public let latencyMs: Int
    /// If non-nil, a context reset occurred just before this turn.
    /// The value is the input token count from the last turn before pruning.
    public let preResetInputTokens: Int?

    // MARK: - Response character counts

    /// Characters in the LLM's text response (`response.text?.count ?? 0`).
    /// Optional for records persisted before this field was added.
    public let outputCharCount: Int?

    // MARK: - Tool call metadata (populated from the LLM response)

    /// Number of tool calls in the LLM's response.
    /// Optional for records persisted before this field was added.
    public let toolCallCount: Int?
    /// Names of tools invoked in this turn, in response order.
    /// Optional for records persisted before this field was added.
    public let toolCallNames: [String]?
    /// Total characters across all tool-call arguments strings in the response.
    /// Optional for records persisted before this field was added.
    public let toolCallArgumentsChars: Int?

    // MARK: - Tool execution stats (measured after tools run)

    /// Total wall-clock milliseconds spent executing tools that this turn's response
    /// requested. Zero if the response had no tool calls. Optional only for records
    /// persisted before this field was added; new records always populate it.
    public let totalToolExecutionMs: Int?
    /// Total characters across all tool-call result strings (the text returned from
    /// tool execution and fed back to the LLM). Optional only for records persisted
    /// before this field was added.
    public let totalToolResultChars: Int?

    // MARK: - Session

    /// One contiguous orchestration run (from `OrchestrationRuntime.start()` to
    /// `stop()` / abort / crash). Optional only for records persisted before the
    /// session concept existed; new records always populate it.
    public let sessionID: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        agentRole: AgentRole,
        taskID: UUID?,
        modelID: String,
        providerType: String,
        providerID: String?,
        configuration: ModelConfiguration?,
        configurationID: UUID? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        latencyMs: Int,
        preResetInputTokens: Int? = nil,
        outputCharCount: Int? = nil,
        toolCallCount: Int? = nil,
        toolCallNames: [String]? = nil,
        toolCallArgumentsChars: Int? = nil,
        totalToolExecutionMs: Int? = nil,
        totalToolResultChars: Int? = nil,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.agentRole = agentRole
        self.taskID = taskID
        self.modelID = modelID
        self.providerType = providerType
        self.providerID = providerID
        self.configuration = configuration
        // Legacy key: prefer explicit argument, else derive from the embedded config so
        // new records always carry both. Once the migration is removed after May 9 2026,
        // this field — and this line — should be deleted.
        self.configurationID = configurationID ?? configuration?.id
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.latencyMs = latencyMs
        self.preResetInputTokens = preResetInputTokens
        self.outputCharCount = outputCharCount
        self.toolCallCount = toolCallCount
        self.toolCallNames = toolCallNames
        self.toolCallArgumentsChars = toolCallArgumentsChars
        self.totalToolExecutionMs = totalToolExecutionMs
        self.totalToolResultChars = totalToolResultChars
        self.sessionID = sessionID
    }
}
