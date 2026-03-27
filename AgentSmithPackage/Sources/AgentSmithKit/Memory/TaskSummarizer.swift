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

    private static let systemPrompt = """
        You are a task summarizer for an AI agent system. Given a completed or failed task's \
        details, produce a concise 2–4 sentence summary covering:

        1. The stated problem or goal
        2. What was accomplished (or why it failed)
        3. How it was accomplished (key approach, tools used, decisions made)

        Write in past tense. Be specific and factual. Include file names, tool names, or \
        technical details when relevant — these help with future search retrieval.

        Respond with ONLY the summary text. No headings, bullet points, or formatting.
        """

    public init(
        provider: any LLMProvider,
        memoryStore: MemoryStore,
        channel: MessageChannel
    ) {
        self.provider = provider
        self.memoryStore = memoryStore
        self.channel = channel
    }

    /// Summarizes a task and saves the embedded summary to the memory store.
    ///
    /// Runs the LLM to generate a summary, then embeds and persists it.
    /// Returns the generated summary text on success, or `nil` if summarization failed.
    /// Errors are posted to the channel rather than thrown, since this runs
    /// as a fire-and-forget background operation.
    @discardableResult
    public func summarizeAndEmbed(task: AgentTask) async -> String? {
        let startTime = Date()
        do {
            let summary = try await generateSummary(for: task)
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            try await memoryStore.saveTaskSummary(
                taskID: task.id,
                title: task.title,
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
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await channel.post(ChannelMessage(
                sender: .agent(.summarizer),
                content: "Task summarization failed for '\(task.title)': \(error.localizedDescription)",
                metadata: [
                    "isError": .bool(true),
                    "latencyMs": .int(latencyMs)
                ]
            ))
            return nil
        }
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

    private func buildUserPrompt(for task: AgentTask) -> String {
        var sections: [String] = []

        sections.append("Title: \(task.title)")
        sections.append("Description: \(task.description)")
        sections.append("Status: \(task.status.rawValue)")

        if let result = task.result, !result.isEmpty {
            // Cap result length to avoid blowing up the prompt.
            let cappedResult = result.count > 2000
                ? String(result.prefix(2000)) + "\n[truncated]"
                : result
            sections.append("Result:\n\(cappedResult)")
        }

        if let commentary = task.commentary, !commentary.isEmpty {
            sections.append("Commentary: \(commentary)")
        }

        if !task.updates.isEmpty {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm:ss"

            let updateLines = task.updates.map { update in
                "[\(dateFormatter.string(from: update.date))] \(update.message)"
            }
            sections.append("Progress updates:\n\(updateLines.joined(separator: "\n"))")
        }

        return sections.joined(separator: "\n\n")
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
