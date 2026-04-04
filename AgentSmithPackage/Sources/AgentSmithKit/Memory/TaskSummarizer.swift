import Foundation

/// Generates concise summaries of completed or failed tasks using a dedicated LLM call.
///
/// Follows the `SecurityEvaluator` pattern: standalone actor with its own `LLMProvider`,
/// focused prompt, and no tools. Each summary captures the problem, outcome, and approach
/// for semantic search retrieval.
public actor TaskSummarizer {
    private let provider: any LLMProvider
    private let memoryStore: MemoryStore
    private let channel: MessageChannel
    private let contextWindowSize: Int
    private let maxOutputTokens: Int

    private static let systemPrompt = """
        You are a task summarizer for an AI agent system. Given a completed or failed task's \
        details, produce a concise 2–4 sentence summary covering:

        1. The stated problem or goal
        2. What was accomplished (or why it failed)
        3. How it was accomplished (key approach, tools used, decisions made)
        4. A numbered list of steps of what happened

        Write in past tense. Be specific and factual. Include file names, tool names, or \
        technical details when relevant — these help with future search retrieval.

        Respond with ONLY the summary text. No headings or bullet points. Use numbered lists only for the step-by-step sequence.
        """

    public init(
        provider: any LLMProvider,
        memoryStore: MemoryStore,
        channel: MessageChannel,
        contextWindowSize: Int,
        maxOutputTokens: Int
    ) {
        self.provider = provider
        self.memoryStore = memoryStore
        self.channel = channel
        self.contextWindowSize = contextWindowSize
        self.maxOutputTokens = maxOutputTokens
    }

    private static let maxRetries = 3
    private static let retryBackoffSeconds: [Double] = [5, 15, 45]

    /// Summarizes a task and saves the embedded summary to the memory store.
    ///
    /// Retries transient HTTP errors (429, 5xx) with exponential backoff.
    /// Returns the generated summary text on success, or `nil` if summarization failed.
    /// Errors are posted to the channel rather than thrown, since this runs
    /// as a fire-and-forget background operation.
    @discardableResult
    public func summarizeAndEmbed(task: AgentTask) async -> String? {
        let startTime = Date()
        var lastError: Error?

        for attempt in 0...Self.maxRetries {
            if attempt > 0 {
                let delay = Self.retryBackoffSeconds[min(attempt - 1, Self.retryBackoffSeconds.count - 1)]
                await channel.post(ChannelMessage(
                    sender: .agent(.summarizer),
                    content: "Summarization retry \(attempt)/\(Self.maxRetries) for '\(task.title)' after \(Int(delay))s",
                    metadata: ["isWarning": .bool(true)]
                ))
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            }

            do {
                let summary = try await generateSummary(for: task)
                let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
                try await memoryStore.saveTaskSummary(
                    task: task,
                    summary: summary,
                    status: task.status
                )
                await channel.post(ChannelMessage(
                    sender: .agent(.summarizer),
                    content: summary,
                    metadata: [
                        "messageKind": .string("task_summarized"),
                        "taskID": .string(task.id.uuidString),
                        "latencyMs": .int(latencyMs)
                    ]
                ))
                return summary
            } catch {
                lastError = error
                guard Self.isRetryableError(error) else { break }
            }
        }

        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        await channel.post(ChannelMessage(
            sender: .agent(.summarizer),
            content: "Task summarization failed for '\(task.title)': \(lastError?.localizedDescription ?? "unknown error")",
            metadata: [
                "isError": .bool(true),
                "latencyMs": .int(latencyMs)
            ]
        ))
        return nil
    }

    // MARK: - Memory Consolidation

    /// Merges two related memory texts into one consolidated memory using an LLM call.
    ///
    /// Retries transient HTTP errors (429, 5xx) with exponential backoff.
    /// Returns the merged text, or `nil` if the LLM call fails.
    public func mergeMemoryTexts(existing: String, new: String) async -> String? {
        let systemPrompt = """
            You are merging two related memories into one consolidated memory. \
            Retain ALL relevant details from both memories. Be concise but complete. \
            If the memories contain conflicting information, prefer the newer memory. \
            Output ONLY the merged memory text — no headings, bullet points, or commentary.
            """
        let userPrompt = "Existing memory:\n\(existing)\n\nNew memory:\n\(new)"

        let messages = [
            LLMMessage(role: .system, text: systemPrompt),
            LLMMessage(role: .user, text: userPrompt)
        ]

        var lastError: Error?
        for attempt in 0...Self.maxRetries {
            if attempt > 0 {
                let delay = Self.retryBackoffSeconds[min(attempt - 1, Self.retryBackoffSeconds.count - 1)]
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            }

            do {
                let response = try await provider.send(messages: messages, tools: [])
                guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                lastError = error
                guard Self.isRetryableError(error) else { break }
            }
        }

        await channel.post(ChannelMessage(
            sender: .agent(.summarizer),
            content: "Memory merge failed: \(lastError?.localizedDescription ?? "unknown error")",
            metadata: ["isError": .bool(true)]
        ))
        return nil
    }

    // MARK: - Private

    private func generateSummary(for task: AgentTask) async throws -> String {
        let userPrompt = buildUserPrompt(for: task)

        let messages = [
            LLMMessage(role: .system, text: Self.systemPrompt),
            LLMMessage(role: .user, text: userPrompt)
        ]

        let response = try await provider.send(messages: messages, tools: [])
        guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizerError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Computes the maximum character budget for the result field based on the
    /// summarizer model's context window, leaving room for output tokens and
    /// the other prompt sections (system prompt, title, description, updates, etc.).
    private var resultCharBudget: Int {
        let inputTokenBudget = contextWindowSize - maxOutputTokens
        // Conservative estimate: ~3 characters per token
        let totalInputChars = inputTokenBudget * 3
        // Reserve space for system prompt (~300 chars) + other fields (~2000 chars generous)
        let overhead = 2300
        return max(1000, totalInputChars - overhead)
    }

    private static let completedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter
    }()

    private static let updateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func buildUserPrompt(for task: AgentTask) -> String {
        var sections: [String] = []

        sections.append("Task ID: \(task.id.uuidString)")
        sections.append("Title: \(task.title)")
        sections.append("Description: \(task.description)")
        sections.append("Status: \(task.status.rawValue)")

        if let completedAt = task.completedAt {
            sections.append("Completed: \(Self.completedDateFormatter.string(from: completedAt))")
        }

        if let result = task.result, !result.isEmpty {
            let budget = resultCharBudget
            let cappedResult = result.count > budget
                ? String(result.prefix(budget)) + "\n[truncated at \(budget) of \(result.count) chars]"
                : result
            sections.append("Result:\n\(cappedResult)")
        }

        if let commentary = task.commentary, !commentary.isEmpty {
            sections.append("Commentary: \(commentary)")
        }

        if !task.updates.isEmpty {
            let updateLines = task.updates.map { update in
                "[\(Self.updateTimeFormatter.string(from: update.date))] \(update.message)"
            }
            sections.append("Progress updates:\n\(updateLines.joined(separator: "\n"))")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Returns `true` for transient HTTP errors that are worth retrying (429, 5xx).
    private static func isRetryableError(_ error: Error) -> Bool {
        let description = error.localizedDescription
        // LLMProviderError.httpError includes the status code in its description.
        // Match 429 (rate limit) and 5xx (server errors like 500, 502, 503, 529).
        if description.hasPrefix("HTTP 429") { return true }
        if let range = description.range(of: #"^HTTP 5\d\d"#, options: .regularExpression) {
            return !range.isEmpty
        }
        // Also retry on URLSession-level network errors (timeouts, connection reset, etc.).
        if (error as NSError).domain == NSURLErrorDomain { return true }
        return false
    }

    public enum SummarizerError: Error, LocalizedError {
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "LLM returned an empty summary"
            }
        }
    }
}
