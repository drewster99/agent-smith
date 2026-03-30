import Foundation
import os

private let logger = Logger(subsystem: "com.agentsmith", category: "Gemini")

/// LLM provider for Google's Gemini API (POST /v1beta/models/{model}:generateContent).
///
/// Key differences from OpenAI-compatible APIs:
/// - Messages use `contents` with `parts` arrays instead of `messages` with `content` strings
/// - The assistant role is called `model`
/// - System instructions are a separate top-level field
/// - Tool definitions use `functionDeclarations` instead of OpenAI's `functions` wrapper
/// - Tool calls are `functionCall` parts; results are `functionResponse` parts
/// - Auth via `key` query parameter or `Authorization: Bearer` header
public struct GeminiProvider: LLMProvider {
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
        // Build URL: {endpoint}/models/{model}:generateContent
        let base = config.endpoint.path.hasSuffix("/")
            ? config.endpoint
            : config.endpoint.appendingPathComponent("")
        let url = base
            .appendingPathComponent("models/\(config.model):generateContent")

        // Append API key as query parameter if provided
        let finalURL: URL
        if !config.apiKey.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw LLMProviderError.invalidResponse
            }
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "key", value: config.apiKey))
            components.queryItems = queryItems
            guard let built = components.url else {
                throw LLMProviderError.invalidResponse
            }
            finalURL = built
        } else {
            finalURL = url
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = buildRequestBody(messages: messages, tools: tools)
        let requestData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = requestData

        logger.debug("Request: POST \(url.absoluteString, privacy: .public) model=\(config.model, privacy: .public)")
        if config.verboseLogging {
            LLMRequestLogger.logRequest(label: "Gemini", url: finalURL, model: config.model, body: body, rawData: requestData)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        if config.verboseLogging {
            LLMRequestLogger.logResponse(label: "Gemini", statusCode: httpResponse.statusCode, data: data)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            logger.error("HTTP \(httpResponse.statusCode, privacy: .public) from \(url.absoluteString, privacy: .public) body=\(responseBody, privacy: .public)")
            throw LLMProviderError.httpError(statusCode: httpResponse.statusCode, body: responseBody, url: url)
        }

        return try parseResponse(data: data)
    }

    // MARK: - Request building

    private func buildRequestBody(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> [String: Any] {
        var systemParts: [String] = []
        var conversationMessages: [LLMMessage] = []

        for message in messages {
            if message.role == .system, let text = message.content.textValue {
                systemParts.append(text)
            } else {
                conversationMessages.append(message)
            }
        }

        // Gemini requires strict user/model alternation. Merge consecutive same-role
        // messages (e.g. a tool result followed by a user message) into one content entry.
        let rawContents = conversationMessages.map(encodeContent)
        let mergedContents = Self.mergeConsecutiveSameRole(rawContents)

        var body: [String: Any] = [
            "contents": mergedContents,
            "generationConfig": [
                "temperature": config.temperature,
                "maxOutputTokens": config.maxTokens
            ] as [String: Any]
        ]

        if !systemParts.isEmpty {
            body["systemInstruction"] = [
                "parts": [["text": systemParts.joined(separator: "\n\n")]]
            ] as [String: Any]
        }

        if !tools.isEmpty {
            body["tools"] = [
                [
                    "functionDeclarations": tools.map { tool in
                        [
                            "name": tool.name,
                            "description": tool.description,
                            "parameters": tool.parameters.mapValues(\.rawValue)
                        ] as [String: Any]
                    }
                ] as [String: Any]
            ]
        }

        return body
    }

    private func encodeContent(_ message: LLMMessage) -> [String: Any] {
        let role = geminiRole(for: message)

        switch message.content {
        case .text(let text):
            var parts: [[String: Any]] = []
            if let images = message.images, !images.isEmpty {
                for image in images {
                    parts.append([
                        "inlineData": [
                            "mimeType": image.mimeType,
                            "data": image.data.base64EncodedString()
                        ]
                    ])
                }
            }
            parts.append(["text": text])
            return ["role": role, "parts": parts]

        case .toolCalls(let calls):
            let parts: [[String: Any]] = calls.map { call in
                [
                    "functionCall": [
                        "name": call.name,
                        "args": parseJSONObject(call.arguments)
                    ] as [String: Any]
                ]
            }
            return ["role": "model", "parts": parts]

        case .mixed(let text, let calls):
            var parts: [[String: Any]] = [["text": text]]
            for call in calls {
                parts.append([
                    "functionCall": [
                        "name": call.name,
                        "args": parseJSONObject(call.arguments)
                    ] as [String: Any]
                ])
            }
            return ["role": "model", "parts": parts]

        case .toolResult(let toolCallID, let content):
            // Gemini uses functionResponse parts for tool results.
            // The toolCallID is used as the function name reference.
            return [
                "role": "user",
                "parts": [
                    [
                        "functionResponse": [
                            "name": toolCallID,
                            "response": [
                                "content": content
                            ]
                        ] as [String: Any]
                    ]
                ]
            ]
        }
    }

    private func geminiRole(for message: LLMMessage) -> String {
        switch message.role {
        case .user, .tool: return "user"
        case .assistant: return "model"
        case .system: return "user" // Should be extracted before reaching here
        }
    }

    // MARK: - Response parsing

    private func parseResponse(data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(non-utf8, \(data.count) bytes)"
            logger.error("Response is not a JSON object: \(preview, privacy: .public)")
            throw LLMProviderError.malformedResponse(detail: "not a JSON object: \(preview)")
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first
        else {
            let keys = json.keys.sorted().joined(separator: ", ")
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(\(data.count) bytes)"
            logger.error("Missing candidates in response. Keys: \(keys, privacy: .public) Body: \(preview, privacy: .public)")
            throw LLMProviderError.malformedResponse(detail: "missing candidates, keys: [\(keys)], body: \(preview)")
        }

        // Gemini returns error finish reasons (e.g. MALFORMED_FUNCTION_CALL) when it fails to
        // produce a valid tool call. Surface these as actionable text so the agent can retry.
        let finishReason = candidate["finishReason"] as? String
        if let finishReason, finishReason != "STOP" && finishReason != "MAX_TOKENS" {
            if candidate["content"] == nil {
                let finishMessage = candidate["finishMessage"] as? String ?? finishReason
                logger.warning("Gemini finished with \(finishReason, privacy: .public): \(finishMessage, privacy: .public)")
                return LLMResponse(
                    text: "[Gemini error: \(finishReason)] \(finishMessage)",
                    toolCalls: []
                )
            }
        }

        // Gemini may return content with no parts (empty response, zero output tokens).
        // Treat as empty text response rather than a parse error.
        guard let content = candidate["content"] as? [String: Any] else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(\(data.count) bytes)"
            logger.error("Missing content in candidate. finishReason=\(finishReason ?? "nil", privacy: .public) Body: \(preview, privacy: .public)")
            throw LLMProviderError.malformedResponse(detail: "missing content, finishReason=\(finishReason ?? "nil"), body: \(preview)")
        }
        let parts = content["parts"] as? [[String: Any]] ?? []

        var text: String?
        var toolCalls: [LLMToolCall] = []

        for part in parts {
            if let textContent = part["text"] as? String {
                if let existing = text {
                    text = existing + textContent
                } else {
                    text = textContent
                }
            } else if let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String {
                let args = functionCall["args"]
                let argString: String
                if let argsDict = args {
                    let argsData = try JSONSerialization.data(withJSONObject: argsDict)
                    argString = String(data: argsData, encoding: .utf8) ?? "{}"
                } else {
                    argString = "{}"
                }
                // Use function name as the synthetic ID because Gemini has no real tool call IDs,
                // and functionResponse needs the function name back (not a UUID).
                toolCalls.append(LLMToolCall(id: name, name: name, arguments: argString))
            }
        }

        return LLMResponse(
            text: text?.isEmpty == true ? nil : text,
            toolCalls: toolCalls
        )
    }

    // MARK: - Message merging

    /// Merges consecutive contents entries that share the same role into a single entry
    /// by concatenating their `parts` arrays. Required because Gemini enforces strict
    /// user/model alternation (e.g. a functionResponse + user text must be one content block).
    private static func mergeConsecutiveSameRole(_ contents: [[String: Any]]) -> [[String: Any]] {
        guard !contents.isEmpty else { return contents }
        var result: [[String: Any]] = []
        for content in contents {
            guard let role = content["role"] as? String else {
                result.append(content)
                continue
            }
            if let lastRole = result.last?["role"] as? String, lastRole == role,
               let existingParts = result[result.count - 1]["parts"] as? [[String: Any]],
               let newParts = content["parts"] as? [[String: Any]] {
                result[result.count - 1]["parts"] = existingParts + newParts
            } else {
                result.append(content)
            }
        }
        return result
    }

    // MARK: - Helpers

    private func parseJSONObject(_ jsonString: String) -> Any {
        guard let data = jsonString.data(using: .utf8) else {
            return [String: Any]()
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.warning("Failed to parse JSON arguments: \(error.localizedDescription, privacy: .public)")
            return [String: Any]()
        }
    }
}
