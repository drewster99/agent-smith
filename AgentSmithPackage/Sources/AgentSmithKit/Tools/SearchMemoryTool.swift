import Foundation

/// Allows agents to search the semantic memory store and prior task summaries.
///
/// Available to both Smith and Brown. Returns matching memories (prioritized) and
/// relevant prior task summaries, ranked by semantic similarity.
public struct SearchMemoryTool: AgentTool {
    public let name = "search_memory"
    public let toolDescription = """
        Search long-term memory and prior task history using natural language. \
        Returns relevant memories (saved insights) and summaries of similar past tasks, \
        ranked by semantic similarity. Use this when approaching a task that might relate \
        to past work, or when looking for previously saved knowledge.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "query": .dictionary([
                "type": .string("string"),
                "description": .string("Natural language search query describing what you're looking for.")
            ]),
            "limit": .dictionary([
                "type": .string("integer"),
                "description": .string("Maximum number of results per category (memories and task summaries). Default: 5.")
            ])
        ]),
        "required": .array([.string("query")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let query) = arguments["query"],
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolCallError.missingRequiredArgument("query")
        }

        let limit: Int
        if case .int(let l) = arguments["limit"] {
            limit = max(1, min(l, 10))
        } else {
            limit = 5
        }

        let results = try await context.memoryStore.searchAll(
            query: query,
            memoryLimit: limit,
            taskLimit: limit
        )

        if results.isEmpty {
            await context.channel.post(ChannelMessage(
                sender: .system,
                content: "No results",
                metadata: [
                    "messageKind": .string("memory_searched"),
                    "searchQuery": .string(query),
                    "memoryCount": .int(0),
                    "taskCount": .int(0)
                ]
            ))
            return "No relevant memories or prior tasks found for: \"\(query)\""
        }

        var sections: [String] = []

        if !results.memories.isEmpty {
            var lines = ["## Relevant Memories"]
            for (index, result) in results.memories.enumerated() {
                let tagText = result.memory.tags.isEmpty ? "" : " [tags: \(result.memory.tags.joined(separator: ", "))]"
                lines.append("\(index + 1). (similarity: \(String(format: "%.2f", result.similarity))) \(result.memory.content)\(tagText)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !results.taskSummaries.isEmpty {
            var lines = ["## Relevant Prior Tasks"]
            for (index, result) in results.taskSummaries.enumerated() {
                lines.append("\(index + 1). (similarity: \(String(format: "%.2f", result.similarity)), status: \(result.summary.status.rawValue)) **\(result.summary.title)**: \(result.summary.summary)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // Post a channel banner so memory searches are visible in the transcript.
        await context.channel.post(ChannelMessage(
            sender: .system,
            content: query,
            metadata: [
                "messageKind": .string("memory_searched"),
                "searchQuery": .string(query),
                "memoryCount": .int(results.memories.count),
                "taskCount": .int(results.taskSummaries.count)
            ]
        ))

        return sections.joined(separator: "\n\n")
    }
}
