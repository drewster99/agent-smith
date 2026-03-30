import Foundation
import os

private let logger = Logger(subsystem: "com.agentsmith", category: "OpenAI")

/// LLM provider for OpenAI-compatible APIs (OpenAI, Ollama, LM Studio, vLLM).
public struct OpenAICompatibleProvider: LLMProvider {
    private let config: LLMConfiguration
    private let session: URLSession
    /// Stable conversation ID for xAI prompt caching. Generated once per provider instance.
    private let conversationID: String

    public init(config: LLMConfiguration, session: URLSession = llmURLSession) {
        self.config = config
        self.session = session
        self.conversationID = UUID().uuidString
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
        if config.providerType == .xAI {
            request.setValue(conversationID, forHTTPHeaderField: "x-grok-conv-id")
        }
        if config.providerType == .zAI {
            request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        }

        let body = buildRequestBody(messages: messages, tools: tools)
        let requestData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = requestData

        logger.debug("Request: POST \(url.absoluteString, privacy: .public) model=\(config.model, privacy: .public)")
        if config.verboseLogging {
            LLMRequestLogger.logRequest(label: "OpenAI", url: url, model: config.model, body: body, rawData: requestData)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        if config.verboseLogging {
            LLMRequestLogger.logResponse(label: "OpenAI", statusCode: httpResponse.statusCode, data: data)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            logger.error("HTTP \(httpResponse.statusCode, privacy: .public) from \(url.absoluteString, privacy: .public) body=\(responseBody, privacy: .public)")
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode, body: responseBody, url: url)
        }

        return try parseResponse(data: data)
    }

    private func buildRequestBody(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> [String: Any] {
        // OpenAI API requires system messages at the start of the conversation.
        // Extract any system messages from arbitrary positions (e.g. per-turn task
        // context appended by AgentActor) and consolidate them into a single leading
        // system message, followed by the remaining non-system messages in order.
        var systemParts: [String] = []
        var nonSystemMessages: [[String: Any]] = []
        for message in messages {
            if message.role == .system, case .text(let text) = message.content {
                systemParts.append(text)
            } else {
                nonSystemMessages.append(encodeMessage(message))
            }
        }
        var orderedMessages: [[String: Any]] = []
        if !systemParts.isEmpty {
            orderedMessages.append(["role": "system", "content": systemParts.joined(separator: "\n\n")])
        }
        orderedMessages.append(contentsOf: nonSystemMessages)

        var body: [String: Any] = [
            "model": config.model,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "messages": orderedMessages
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
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(non-utf8, \(data.count) bytes)"
            logger.error("Response is not a JSON object: \(preview, privacy: .public)")
            throw LLMProviderError.malformedResponse(detail: "not a JSON object: \(preview)")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else {
            let keys = json.keys.sorted().joined(separator: ", ")
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(\(data.count) bytes)"
            logger.error("Missing choices[0].message in response. Keys: \(keys, privacy: .public) Body: \(preview, privacy: .public)")
            throw LLMProviderError.malformedResponse(detail: "missing choices[0].message, keys: [\(keys)], body: \(preview)")
        }

        let text = message["content"] as? String
        let reasoningContent = message["reasoning_content"] as? String
        let toolCallsRaw = message["tool_calls"] as? [[String: Any]]

        var toolCalls: [LLMToolCall] = []
        if let rawCalls = toolCallsRaw {
            for raw in rawCalls {
                guard let id = raw["id"] as? String,
                      let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String
                else {
                    logger.warning("Skipping malformed tool_call entry: missing id, function, or name")
                    continue
                }

                let arguments: String
                if let argsObj = function["arguments"] {
                    if let argsString = argsObj as? String {
                        arguments = argsString
                    } else if let argsData = try? JSONSerialization.data(withJSONObject: argsObj),
                              let argsString = String(data: argsData, encoding: .utf8) {
                        arguments = argsString
                    } else {
                        logger.warning("Could not serialize tool_call arguments for \(name, privacy: .public), defaulting to {}")
                        arguments = "{}"
                    }
                } else {
                    arguments = "{}"
                }

                toolCalls.append(LLMToolCall(id: id, name: name, arguments: arguments))
            }
        }

        return LLMResponse(
            text: text?.isEmpty == true ? nil : text,
            toolCalls: toolCalls,
            reasoning: reasoningContent
        )
    }
}

public enum LLMProviderError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String, url: URL? = nil)
    case malformedResponse(detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Response was not a valid HTTP response"
        case .httpError(let code, let body, let url):
            let detail = body.isEmpty ? (url?.absoluteString ?? "empty body") : body
            return "HTTP \(code): \(detail)"
        case .malformedResponse(let detail):
            return "Could not parse LLM response: \(detail)"
        }
    }
}
