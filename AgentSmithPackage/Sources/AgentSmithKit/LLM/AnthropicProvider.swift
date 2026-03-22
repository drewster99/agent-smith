import Foundation
import os

private let logger = Logger(subsystem: "com.agentsmith", category: "Anthropic")

/// LLM provider for the Anthropic Messages API.
public struct AnthropicProvider: LLMProvider {
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
        // Normalize: accept both "https://api.anthropic.com" and ".../v1" as endpoint.
        let base = config.endpoint.path.hasSuffix("/v1")
            ? config.endpoint
            : config.endpoint.appendingPathComponent("v1")
        let url = base.appendingPathComponent("messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = buildRequestBody(messages: messages, tools: tools)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.debug("Request: POST \(url.absoluteString, privacy: .public) model=\(config.model, privacy: .public)")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
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
        // Anthropic requires system prompt separate from messages
        var systemPrompt: String?
        var conversationMessages: [LLMMessage] = []

        for message in messages {
            if message.role == .system, let text = message.content.textValue {
                systemPrompt = text
            } else {
                conversationMessages.append(message)
            }
        }

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "messages": conversationMessages.map(encodeMessage)
        ]

        if let systemPrompt {
            body["system"] = systemPrompt
        }

        if let budget = config.thinkingBudget, budget > 0 {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": budget
            ] as [String: Any]
        }

        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parameters.mapValues(\.rawValue)
                ] as [String: Any]
            }
        }

        return body
    }

    /// Maps an LLMMessage role to the Anthropic API role string.
    private func anthropicRole(for message: LLMMessage) -> String {
        switch message.role {
        case .user: return "user"
        case .assistant: return "assistant"
        // System messages should have been extracted in buildRequestBody.
        // Tool results are encoded as "user" messages per Anthropic API.
        case .system, .tool: return "user"
        }
    }

    private func encodeMessage(_ message: LLMMessage) -> [String: Any] {
        let role = anthropicRole(for: message)

        switch message.content {
        case .text(let text):
            // If there are images, encode as content blocks array (multimodal)
            if let images = message.images, !images.isEmpty {
                var blocks: [[String: Any]] = images.map { image in
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": image.mimeType,
                            "data": image.data.base64EncodedString()
                        ]
                    ] as [String: Any]
                }
                blocks.append(["type": "text", "text": text])
                return [
                    "role": role,
                    "content": blocks
                ]
            }
            return [
                "role": role,
                "content": text
            ]
        case .toolCalls(let calls):
            let content: [[String: Any]] = calls.map { call in
                [
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": Self.parseToolArguments(call.arguments)
                ]
            }
            return ["role": "assistant", "content": content]
        case .mixed(let text, let calls):
            var content: [[String: Any]] = [
                ["type": "text", "text": text]
            ]
            content.append(contentsOf: calls.map { call in
                [
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": Self.parseToolArguments(call.arguments)
                ] as [String: Any]
            })
            return ["role": "assistant", "content": content]
        case .toolResult(let toolCallID, let resultContent):
            return [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolCallID,
                        "content": resultContent
                    ]
                ]
            ]
        }
    }

    /// Parses a JSON argument string back into a Foundation object for the API request body.
    private static func parseToolArguments(_ jsonString: String) -> Any {
        guard let data = jsonString.data(using: .utf8) else {
            return [String: Any]()
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            // Arguments were already valid JSON from the LLM response; re-parse failure is unexpected
            return [String: Any]()
        }
    }

    private func parseResponse(data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]]
        else {
            throw LLMProviderError.malformedResponse
        }

        var text: String?
        var toolCalls: [LLMToolCall] = []

        for block in contentBlocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "thinking":
                // Extended thinking block — log but don't include in response text.
                // The thinking content is internal reasoning, not user-facing output.
                if let thinking = block["thinking"] as? String {
                    logger.debug("Thinking block (\(thinking.count) chars)")
                }
            case "text":
                text = block["text"] as? String
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String,
                      let input = block["input"]
                else { continue }
                let argData = try JSONSerialization.data(withJSONObject: input)
                let argString = String(data: argData, encoding: .utf8) ?? "{}"
                toolCalls.append(LLMToolCall(id: id, name: name, arguments: argString))
            default:
                break
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
