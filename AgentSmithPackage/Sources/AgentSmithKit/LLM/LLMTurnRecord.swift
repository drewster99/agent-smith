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

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        inputDelta: [LLMMessage],
        response: LLMResponse,
        totalMessageCount: Int,
        contextSnapshot: [LLMMessage] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.inputDelta = inputDelta
        self.response = response
        self.totalMessageCount = totalMessageCount
        self.contextSnapshot = contextSnapshot
    }
}
