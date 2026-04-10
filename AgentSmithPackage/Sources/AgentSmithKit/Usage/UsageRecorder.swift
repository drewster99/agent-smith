import Foundation
import SwiftLLMKit

/// Metadata the caller provides to describe the context of an LLM call.
/// Separates "what the caller knows" from "what the response contains."
public struct LLMCallContext: Sendable {
    public let agentRole: AgentRole
    public let taskID: UUID?
    public let modelID: String
    public let providerType: String
    public let providerID: String?
    public let configurationID: UUID?
    public let preResetInputTokens: Int?

    public init(
        agentRole: AgentRole,
        taskID: UUID?,
        modelID: String,
        providerType: String,
        providerID: String?,
        configurationID: UUID?,
        preResetInputTokens: Int? = nil
    ) {
        self.agentRole = agentRole
        self.taskID = taskID
        self.modelID = modelID
        self.providerType = providerType
        self.providerID = providerID
        self.configurationID = configurationID
        self.preResetInputTokens = preResetInputTokens
    }
}

/// Records LLM token usage to a ``UsageStore`` given a response and caller context.
///
/// All LLM callers should use this after every `provider.send()` call to ensure
/// consistent usage tracking across the entire app.
public enum UsageRecorder {
    /// Records usage from an LLM response, if token usage data is present.
    ///
    /// No-op if `response.usage` is nil (e.g. local models that don't report tokens).
    public static func record(
        response: LLMResponse,
        context: LLMCallContext,
        latencyMs: Int,
        to store: UsageStore
    ) async {
        guard let usage = response.usage else { return }
        await store.append(UsageRecord(
            agentRole: context.agentRole,
            taskID: context.taskID,
            modelID: context.modelID,
            providerType: context.providerType,
            providerID: context.providerID,
            configurationID: context.configurationID,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens,
            latencyMs: latencyMs,
            preResetInputTokens: context.preResetInputTokens
        ))
    }
}
