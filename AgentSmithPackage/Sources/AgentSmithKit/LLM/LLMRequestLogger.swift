import Foundation

/// Controls verbose request/response file logging for each agent and service.
///
/// When enabled, full JSON request and response bodies are written to
/// `$TMPDIR/AgentSmith-LLM-Logs/` with timestamped filenames.
/// Toggle individual flags to debug specific agents without noise from others.
public enum LLMRequestLogger {
    // MARK: - Per-agent logging flags

    /// Log all LLM requests/responses for Agent Smith.
    public static let logSmith = true
    /// Log all LLM requests/responses for Agent Brown.
    public static let logBrown = true
    /// Log all LLM requests/responses for Agent Jones.
    public static let logJones = true
    /// Log model list fetches (provider API calls).
    public static let logModelFetch = true
    /// Log LiteLLM metadata fetches.
    public static let logLiteLLM = true

    // MARK: - Log directory

    static let logDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSmith-LLM-Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Shared helpers

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss.SSS"
        return f.string(from: Date())
    }

    /// Logs a full request body to a JSON file and prints a console summary.
    static func logRequest(
        label: String,
        url: URL,
        model: String,
        body: [String: Any],
        rawData: Data
    ) {
        let stamp = timestamp()
        let safeModel = model.replacingOccurrences(of: "/", with: "_")
        let prefix = "\(stamp)_\(label)_\(safeModel)"

        let toolCount: Int = {
            // OpenAI/Anthropic use "tools", Gemini wraps in functionDeclarations
            if let tools = body["tools"] as? [[String: Any]] {
                // Gemini nests tools under functionDeclarations
                if let decls = tools.first?["functionDeclarations"] as? [[String: Any]] {
                    return decls.count
                }
                return tools.count
            }
            return 0
        }()
        // OpenAI/Anthropic use "messages", Gemini uses "contents"
        let messageCount = (body["messages"] as? [[String: Any]])?.count
            ?? (body["contents"] as? [[String: Any]])?.count
            ?? 0
        print("[\(label)] REQUEST \(stamp) → \(url.absoluteString) model=\(model) messages=\(messageCount) tools=\(toolCount)")

        if let pretty = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            let file = logDirectory.appendingPathComponent("\(prefix)_request.json")
            try? prettyString.write(to: file, atomically: true, encoding: .utf8)
            print("[\(label)]   Full request logged to \(file.path)")
        }
    }

    /// Logs a full response body to a JSON file and prints a console summary.
    static func logResponse(
        label: String,
        statusCode: Int,
        data: Data
    ) {
        let stamp = timestamp()
        let size = data.count
        var summary = "status=\(statusCode) bytes=\(size)"

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI/Anthropic-style: choices[0].message or content blocks
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any] {
                let hasContent = (message["content"] as? String).map { !$0.isEmpty } ?? false
                let toolCallCount = (message["tool_calls"] as? [[String: Any]])?.count ?? 0
                summary += " hasContent=\(hasContent) toolCalls=\(toolCallCount)"
            } else if let message = json["message"] as? [String: Any] {
                // Ollama-style
                let hasContent = (message["content"] as? String).map { !$0.isEmpty } ?? false
                let toolCallCount = (message["tool_calls"] as? [[String: Any]])?.count ?? 0
                summary += " hasContent=\(hasContent) toolCalls=\(toolCallCount)"
            } else if let contentBlocks = json["content"] as? [[String: Any]] {
                // Anthropic-style
                let textBlocks = contentBlocks.filter { ($0["type"] as? String) == "text" }.count
                let toolBlocks = contentBlocks.filter { ($0["type"] as? String) == "tool_use" }.count
                summary += " textBlocks=\(textBlocks) toolUseBlocks=\(toolBlocks)"
            }
        }
        print("[\(label)] RESPONSE \(stamp) \(summary)")

        let file = logDirectory.appendingPathComponent("\(stamp)_\(label)_response.json")
        if let parsed = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            try? prettyString.write(to: file, atomically: true, encoding: .utf8)
            print("[\(label)]   Full response logged to \(file.path)")
        } else {
            try? data.write(to: file)
            print("[\(label)]   Raw response logged to \(file.path)")
        }
    }
}
