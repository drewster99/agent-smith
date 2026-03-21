import Foundation

/// Abstraction over any LLM backend that supports tool calling.
public protocol LLMProvider: Sendable {
    /// Sends a conversation to the LLM and returns the response.
    /// - Parameters:
    ///   - messages: The conversation history.
    ///   - tools: Available tool definitions the model may invoke.
    /// - Returns: The model's response (text, tool calls, or both).
    func send(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> LLMResponse
}

/// A URLSession configured with a 10-minute request timeout for LLM API calls.
/// Local models (Ollama) can take minutes to generate complex responses;
/// the default 60-second URLSession timeout causes spurious failures.
public let llmURLSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 600
    return URLSession(configuration: config)
}()
