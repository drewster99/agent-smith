import Foundation

/// LLM provider for OpenAI-compatible APIs (OpenAI, Ollama, LM Studio, vLLM).
public struct OpenAICompatibleProvider: LLMProvider {
    private let config: LLMConfiguration
    private let session: URLSession

    public init(config: LLMConfiguration, session: URLSession = llmURLSession) {
        self.config = config
        self.session = session
    }

    public func send(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> LLMResponse {
        let url = config.endpoint.appendingPathComponent("chat/completions")
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
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        return try parseResponse(data: data)
    }

    private func buildRequestBody(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "messages": messages.map(encodeMessage)
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
            // If there are images, encode as content parts array (multimodal)
            if let images = message.images, !images.isEmpty {
                var parts: [[String: Any]] = images.map { image in
                    [
                        "type": "image_url",
                        "image_url": [
                            "url": "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
                        ]
                    ] as [String: Any]
                }
                parts.append(["type": "text", "text": text])
                result["content"] = parts
            } else {
                result["content"] = text
            }
        case .toolCalls(let calls):
            result["tool_calls"] = calls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments
                    ]
                ] as [String: Any]
            }
        case .mixed(let text, let calls):
            result["content"] = text
            result["tool_calls"] = calls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments
                    ]
                ] as [String: Any]
            }
        case .toolResult(let toolCallID, let content):
            result["role"] = "tool"
            result["tool_call_id"] = toolCallID
            result["content"] = content
        }

        return result
    }

    private func parseResponse(data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw LLMProviderError.malformedResponse
        }

        let text = message["content"] as? String
        let toolCallsRaw = message["tool_calls"] as? [[String: Any]]

        var toolCalls: [LLMToolCall] = []
        if let rawCalls = toolCallsRaw {
            for raw in rawCalls {
                guard let id = raw["id"] as? String,
                      let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let arguments = function["arguments"] as? String
                else { continue }
                toolCalls.append(LLMToolCall(id: id, name: name, arguments: arguments))
            }
        }

        if let text, !toolCalls.isEmpty {
            return .mixed(text: text, toolCalls: toolCalls)
        } else if !toolCalls.isEmpty {
            return .toolCalls(toolCalls)
        } else {
            return .text(text ?? "")
        }
    }
}

public enum LLMProviderError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Response was not a valid HTTP response"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .malformedResponse:
            return "Could not parse LLM response"
        }
    }
}
