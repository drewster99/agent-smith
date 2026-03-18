import Foundation

/// LLM provider for Ollama's native API (POST /api/chat, GET /api/tags).
///
/// The `endpoint` in `LLMConfiguration` must be the base path that `/chat` is appended to,
/// e.g. `http://localhost:11434/api`. Do **not** include a trailing `/chat` in the endpoint itself.
///
/// Differs from the OpenAI-compatible provider in several ways:
/// - Tool arguments in responses are JSON objects, not strings
/// - Tool calls have no `id` — synthetic UUIDs are generated
/// - Tool results omit `tool_call_id`
/// - Images are passed as a base64 array rather than content parts
public struct OllamaProvider: LLMProvider {
    private let config: LLMConfiguration
    private let session: URLSession

    public init(config: LLMConfiguration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func send(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> LLMResponse {
        let url = config.endpoint.appendingPathComponent("chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = buildRequestBody(messages: messages, tools: tools)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode, body: responseBody)
        }

        return try parseResponse(data: data)
    }

    private func buildRequestBody(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "messages": messages.map(encodeMessage),
            "options": [
                "temperature": config.temperature,
                "num_predict": config.maxTokens
            ] as [String: Any]
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.mapValues(\.rawValue)
                    ] as [String: Any]
                ] as [String: Any]
            }
        }

        return body
    }

    private func encodeMessage(_ message: LLMMessage) -> [String: Any] {
        var result: [String: Any] = ["role": message.role.rawValue]

        switch message.content {
        case .text(let text):
            result["content"] = text
            if let images = message.images, !images.isEmpty {
                // Ollama multimodal: base64 image array alongside text content
                result["images"] = images.map { $0.data.base64EncodedString() }
            }
        case .toolCalls(let calls):
            result["tool_calls"] = calls.map(encodeToolCall)
        case .mixed(let text, let calls):
            result["content"] = text
            result["tool_calls"] = calls.map(encodeToolCall)
        case .toolResult(_, let content):
            // Ollama tool results don't use tool_call_id
            result["role"] = "tool"
            result["content"] = content
        }

        return result
    }

    private func encodeToolCall(_ call: LLMToolCall) -> [String: Any] {
        [
            "function": [
                "name": call.name,
                "arguments": argumentsObject(from: call.arguments)
            ] as [String: Any]
        ]
    }

    /// Converts a JSON string back to a JSON object for Ollama's native format.
    private func argumentsObject(from jsonString: String) -> Any {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return jsonString
        }
        return obj
    }

    private func parseResponse(data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any]
        else {
            throw LLMProviderError.malformedResponse
        }

        let text = message["content"] as? String
        let toolCallsRaw = message["tool_calls"] as? [[String: Any]]

        var toolCalls: [LLMToolCall] = []
        if let rawCalls = toolCallsRaw {
            for raw in rawCalls {
                guard let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String
                else { continue }

                // Ollama returns arguments as a JSON object, not a string
                let arguments: String
                if let argsObj = function["arguments"] {
                    if let argsString = argsObj as? String {
                        arguments = argsString
                    } else if let argsData = try? JSONSerialization.data(withJSONObject: argsObj),
                              let argsString = String(data: argsData, encoding: .utf8) {
                        arguments = argsString
                    } else {
                        arguments = "{}"
                    }
                } else {
                    arguments = "{}"
                }

                // Ollama doesn't return tool call IDs — generate synthetic ones
                toolCalls.append(LLMToolCall(id: UUID().uuidString, name: name, arguments: arguments))
            }
        }

        let hasText = text != nil && !text!.isEmpty
        if hasText && !toolCalls.isEmpty {
            return .mixed(text: text!, toolCalls: toolCalls)
        } else if !toolCalls.isEmpty {
            return .toolCalls(toolCalls)
        } else {
            return .text(text ?? "")
        }
    }
}
