import Foundation

/// The response from an LLM call.
public struct LLMResponse: Sendable {
    /// The text content of the response, if any.
    public let text: String?
    /// Tool calls requested by the model, if any.
    public let toolCalls: [LLMToolCall]
    /// Reasoning/thinking content from models that support it (e.g., DeepSeek-R1, o1).
    /// Not part of the visible response — used for inspector display only.
    public let reasoning: String?

    public init(text: String? = nil, toolCalls: [LLMToolCall] = [], reasoning: String? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.reasoning = reasoning
    }
}
