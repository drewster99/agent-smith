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

        var body: [String: Any] = [
            "contents": conversationMessages.map(encodeContent),
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
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            throw LLMProviderError.malformedResponse
        }

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
