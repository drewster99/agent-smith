import Foundation

/// The response from an LLM call.
public enum LLMResponse: Sendable {
    case text(String)
    case toolCalls([LLMToolCall])
    /// Some models return both text and tool calls in one response.
    case mixed(text: String, toolCalls: [LLMToolCall])

    /// All tool calls present in this response, if any.
    public var toolCalls: [LLMToolCall] {
        switch self {
        case .text: return []
        case .toolCalls(let calls): return calls
        case .mixed(_, let calls): return calls
        }
    }

    /// The text portion of the response, if any.
    public var text: String? {
        switch self {
        case .text(let value): return value
        case .toolCalls: return nil
        case .mixed(let value, _): return value
        }
    }
}
