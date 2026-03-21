import Foundation
import os

private let logger = Logger(subsystem: "com.agentsmith", category: "Ollama")

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

    public init(config: LLMConfiguration, session: URLSession = llmURLSession) {
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

        // Only normalize when no tools are in use — normalization converts tool results
        // to user messages for backends that don't understand the "tool" role, but breaks
        // the tool_call/tool_result pairing that Ollama requires when tools ARE defined.
        let finalMessages = tools.isEmpty ? Self.normalizeMessages(messages) : messages
        let body = buildRequestBody(messages: finalMessages, tools: tools)
        let requestData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = requestData

        logger.debug("Request: POST \(url.absoluteString, privacy: .public) model=\(config.model, privacy: .public)")
        Self.logRequest(url: url, model: config.model, body: body, rawData: requestData)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        Self.logResponse(statusCode: httpResponse.statusCode, data: data)

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

    // MARK: - Message normalization

    /// Ensures the conversation history satisfies strict role alternation rules.
    /// Some model backends reject conversations where roles don't strictly alternate
    /// user/assistant, or don't understand the "tool" role at all.
    ///
    /// This pass:
    /// 1. Merges consecutive user messages.
    /// 2. Converts orphaned tool results (not supported by some backends) into user messages.
    /// 3. Ensures no two assistant messages appear back-to-back.
    private static func normalizeMessages(_ messages: [LLMMessage]) -> [LLMMessage] {
        guard !messages.isEmpty else { return messages }

        var result: [LLMMessage] = []

        for message in messages {
            // System messages pass through; they sit at the start and don't affect alternation.
            if message.role == .system {
                result.append(message)
                continue
            }

            // Convert tool results into user messages so backends that don't understand
            // the "tool" role still receive the information.
            let effectiveMessage: LLMMessage
            if message.role == .tool {
                let text: String
                if case .toolResult(let callID, let content) = message.content {
                    text = "[Tool result for \(callID)]: \(content)"
                } else {
                    text = "[Tool result]"
                }
                effectiveMessage = LLMMessage(role: .user, text: text)
            } else {
                effectiveMessage = message
            }

            // Merge consecutive same-role messages.
            if let lastIndex = result.indices.last,
               result[lastIndex].role == effectiveMessage.role,
               result[lastIndex].role != .system {
                // Merge text content
                let existingText: String
                switch result[lastIndex].content {
                case .text(let t): existingText = t
                case .toolCalls: existingText = ""
                case .mixed(let t, _): existingText = t
                case .toolResult(_, let t): existingText = t
                }
                let newText: String
                switch effectiveMessage.content {
                case .text(let t): newText = t
                case .toolCalls: newText = ""
                case .mixed(let t, _): newText = t
                case .toolResult(_, let t): newText = t
                }
                let merged = [existingText, newText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                result[lastIndex] = LLMMessage(
                    role: effectiveMessage.role,
                    text: merged,
                    images: (result[lastIndex].images ?? []) + (effectiveMessage.images ?? [])
                )
            } else {
                result.append(effectiveMessage)
            }
        }

        return result
    }

    // MARK: - Debug logging

    private static let logDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSmith-LLM-Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Creates a fresh formatter per call to avoid thread-safety issues with `DateFormatter`.
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss.SSS"
        return f.string(from: Date())
    }

    private static func logRequest(url: URL, model: String, body: [String: Any], rawData: Data) {
        let stamp = timestamp()
        let prefix = "\(stamp)_\(model.replacingOccurrences(of: "/", with: "_"))"

        // Log tool definitions separately for readability
        let toolCount = (body["tools"] as? [[String: Any]])?.count ?? 0
        let messageCount = (body["messages"] as? [[String: Any]])?.count ?? 0
        print("[OllamaProvider] REQUEST \(stamp) → \(url.absoluteString) model=\(model) messages=\(messageCount) tools=\(toolCount)")

        // Write full request body
        if let pretty = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            let file = logDirectory.appendingPathComponent("\(prefix)_request.json")
            try? prettyString.write(to: file, atomically: true, encoding: .utf8)
            print("[OllamaProvider]   Full request logged to \(file.path)")
        }
    }

    private static func logResponse(statusCode: Int, data: Data) {
        let stamp = timestamp()
        let size = data.count

        // Parse for summary
        var summary = "status=\(statusCode) bytes=\(size)"
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? [String: Any] {
            let hasContent = (message["content"] as? String).map { !$0.isEmpty } ?? false
            let toolCallCount = (message["tool_calls"] as? [[String: Any]])?.count ?? 0
            summary += " hasContent=\(hasContent) toolCalls=\(toolCallCount)"

            // Log the raw tool_calls structure if present
            if toolCallCount > 0, let toolCalls = message["tool_calls"] {
                if let tcData = try? JSONSerialization.data(withJSONObject: toolCalls, options: .prettyPrinted),
                   let tcString = String(data: tcData, encoding: .utf8) {
                    print("[OllamaProvider]   tool_calls: \(tcString)")
                }
            }

            // Log first 500 chars of content if it looks like it might contain text-formatted tool calls
            if let content = message["content"] as? String, !content.isEmpty {
                let preview = String(content.prefix(500))
                let looksLikeToolCall = content.contains("<function_calls>") ||
                    content.contains("<invoke") ||
                    content.contains("```tool_code")
                if looksLikeToolCall {
                    print("[OllamaProvider]   ⚠️ Content appears to contain text-formatted tool calls:")
                    print("[OllamaProvider]   \(preview)")
                }
            }
        }
        print("[OllamaProvider] RESPONSE \(stamp) \(summary)")

        // Write full response
        let file = logDirectory.appendingPathComponent("\(stamp)_response.json")
        if let pretty = try? JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            try? prettyString.write(to: file, atomically: true, encoding: .utf8)
            print("[OllamaProvider]   Full response logged to \(file.path)")
        } else {
            // Fall back to raw data if it's not valid JSON
            try? data.write(to: file)
            print("[OllamaProvider]   Raw response logged to \(file.path)")
        }
    }

    // MARK: - Response parsing

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

        // Fallback: if no structured tool_calls, check content for text-formatted tool calls.
        // Some models output tool calls as text instead of using Ollama's native tool_calls
        // structure. We support two formats:
        //  1. Anthropic XML: <function_calls><invoke name="...">...</invoke></function_calls>
        //  2. tool_code fences: ```tool_code\nfunction_name(arg: value)\n```
        if toolCalls.isEmpty, let content = text {
            var parsedCalls: [LLMToolCall] = []
            var strippedContent = content

            if content.contains("<function_calls>") {
                parsedCalls = Self.parseXMLToolCalls(from: content)
                strippedContent = Self.stripXMLToolCalls(from: content)
            } else if content.contains("```tool_code") {
                parsedCalls = Self.parseToolCodeCalls(from: content)
                strippedContent = Self.stripToolCodeBlocks(from: content)
            }

            if !parsedCalls.isEmpty {
                let remainingText = strippedContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if remainingText.isEmpty {
                    return .toolCalls(parsedCalls)
                } else {
                    return .mixed(text: remainingText, toolCalls: parsedCalls)
                }
            }
        }

        let hasText = text != nil && !(text ?? "").isEmpty
        if hasText && !toolCalls.isEmpty {
            return .mixed(text: text!, toolCalls: toolCalls)
        } else if !toolCalls.isEmpty {
            return .toolCalls(toolCalls)
        } else {
            return .text(text ?? "")
        }
    }

    // MARK: - XML tool call parsing

    /// Parses Anthropic-style XML tool calls from content text.
    ///
    /// Expected format:
    /// ```xml
    /// <function_calls>
    /// <invoke name="tool_name">
    /// <parameter name="param_name">value</parameter>
    /// </invoke>
    /// </function_calls>
    /// ```
    private static func parseXMLToolCalls(from content: String) -> [LLMToolCall] {
        var calls: [LLMToolCall] = []

        // Find all <function_calls>...</function_calls> blocks
        let blockPattern = #"<function_calls>\s*(.*?)\s*</function_calls>"#
        guard let blockRegex = try? NSRegularExpression(
            pattern: blockPattern,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }

        let nsContent = content as NSString
        let blockMatches = blockRegex.matches(
            in: content,
            range: NSRange(location: 0, length: nsContent.length)
        )

        for blockMatch in blockMatches {
            let blockBody = nsContent.substring(with: blockMatch.range(at: 1))
            calls.append(contentsOf: parseInvocations(from: blockBody))
        }

        return calls
    }

    /// Parses `<invoke>` elements within a `<function_calls>` block.
    private static func parseInvocations(from block: String) -> [LLMToolCall] {
        var calls: [LLMToolCall] = []

        let invokePattern = #"<invoke\s+name="([^"]+)">\s*(.*?)\s*</invoke>"#
        guard let invokeRegex = try? NSRegularExpression(
            pattern: invokePattern,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }

        let nsBlock = block as NSString
        let invokeMatches = invokeRegex.matches(
            in: block,
            range: NSRange(location: 0, length: nsBlock.length)
        )

        for invokeMatch in invokeMatches {
            let toolName = nsBlock.substring(with: invokeMatch.range(at: 1))
            let paramsBody = nsBlock.substring(with: invokeMatch.range(at: 2))
            let arguments = parseParameters(from: paramsBody)

            let argsJSON: String
            if arguments.isEmpty {
                argsJSON = "{}"
            } else if let argsData = try? JSONSerialization.data(withJSONObject: arguments),
                      let argsString = String(data: argsData, encoding: .utf8) {
                argsJSON = argsString
            } else {
                argsJSON = "{}"
            }

            calls.append(LLMToolCall(id: UUID().uuidString, name: toolName, arguments: argsJSON))
        }

        return calls
    }

    /// Parses `<parameter>` elements into a dictionary.
    private static func parseParameters(from body: String) -> [String: Any] {
        var params: [String: Any] = [:]

        let paramPattern = #"<parameter\s+name="([^"]+)"(?:\s+[^>]*)?>([^<]*)</parameter>"#
        guard let paramRegex = try? NSRegularExpression(
            pattern: paramPattern,
            options: [.dotMatchesLineSeparators]
        ) else { return params }

        let nsBody = body as NSString
        let paramMatches = paramRegex.matches(
            in: body,
            range: NSRange(location: 0, length: nsBody.length)
        )

        for paramMatch in paramMatches {
            let name = nsBody.substring(with: paramMatch.range(at: 1))
            let value = nsBody.substring(with: paramMatch.range(at: 2))

            // Try to interpret as JSON value (number, bool, etc.) before falling back to string
            if let data = value.data(using: .utf8),
               let jsonValue = try? JSONSerialization.jsonObject(with: data) {
                // Only use JSON interpretation for non-string types to avoid
                // double-interpreting strings that happen to be valid JSON
                if jsonValue is NSNumber {
                    params[name] = jsonValue
                } else {
                    params[name] = value
                }
            } else {
                params[name] = value
            }
        }

        return params
    }

    /// Removes `<function_calls>...</function_calls>` blocks from content text.
    private static func stripXMLToolCalls(from content: String) -> String {
        let pattern = #"<function_calls>\s*.*?\s*</function_calls>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return content }
        return regex.stringByReplacingMatches(
            in: content,
            range: NSRange(location: 0, length: (content as NSString).length),
            withTemplate: ""
        )
    }

    // MARK: - tool_code fence parsing

    /// Parses tool calls from ` ```tool_code ` fenced code blocks.
    ///
    /// Expected format:
    /// ```
    /// ```tool_code
    /// function_name(arg1: value1, arg2: "string value")
    /// ```
    /// ```
    private static func parseToolCodeCalls(from content: String) -> [LLMToolCall] {
        var calls: [LLMToolCall] = []

        // Match ```tool_code ... ``` blocks
        let blockPattern = #"```tool_code\s*\n(.*?)\n\s*```"#
        guard let blockRegex = try? NSRegularExpression(
            pattern: blockPattern,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }

        let nsContent = content as NSString
        let matches = blockRegex.matches(
            in: content,
            range: NSRange(location: 0, length: nsContent.length)
        )

        for match in matches {
            let body = nsContent.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse: function_name(arg1: value1, arg2: "value2")
            let callPattern = #"^(\w+)\((.*)\)$"#
            guard let callRegex = try? NSRegularExpression(
                pattern: callPattern,
                options: [.dotMatchesLineSeparators]
            ) else { continue }

            let nsBody = body as NSString
            guard let callMatch = callRegex.firstMatch(
                in: body,
                range: NSRange(location: 0, length: nsBody.length)
            ) else { continue }

            let funcName = nsBody.substring(with: callMatch.range(at: 1))
            let argsString = nsBody.substring(with: callMatch.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let arguments = parseToolCodeArguments(argsString)
            let argsJSON: String
            if arguments.isEmpty {
                argsJSON = "{}"
            } else if let argsData = try? JSONSerialization.data(withJSONObject: arguments),
                      let json = String(data: argsData, encoding: .utf8) {
                argsJSON = json
            } else {
                argsJSON = "{}"
            }

            calls.append(LLMToolCall(id: UUID().uuidString, name: funcName, arguments: argsJSON))
        }

        return calls
    }

    /// Parses `key: value` arguments from a function call string like `arg1: "hello", arg2: true`.
    private static func parseToolCodeArguments(_ argsString: String) -> [String: Any] {
        guard !argsString.isEmpty else { return [:] }

        var params: [String: Any] = [:]

        // Split on commas that are not inside quotes.
        // Walk the string tracking quote state to split correctly.
        var parts: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for char in argsString {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                current.append(char)
                continue
            }
            if char == "\"" {
                inQuote.toggle()
                current.append(char)
            } else if char == "," && !inQuote {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }

        for part in parts {
            // Split on first ":"
            guard let colonIndex = part.firstIndex(of: ":") else { continue }
            let key = String(part[part.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(part[part.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                // Quoted string — strip quotes
                value = String(value.dropFirst().dropLast())
                params[key] = value
            } else if value == "true" {
                params[key] = true
            } else if value == "false" {
                params[key] = false
            } else if value == "null" || value == "nil" {
                params[key] = NSNull()
            } else if let intVal = Int(value) {
                params[key] = intVal
            } else if let doubleVal = Double(value) {
                params[key] = doubleVal
            } else {
                params[key] = value
            }
        }

        return params
    }

    /// Removes ` ```tool_code ... ``` ` blocks from content text.
    private static func stripToolCodeBlocks(from content: String) -> String {
        let pattern = #"```tool_code\s*\n.*?\n\s*```"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return content }
        return regex.stringByReplacingMatches(
            in: content,
            range: NSRange(location: 0, length: (content as NSString).length),
            withTemplate: ""
        )
    }
}
