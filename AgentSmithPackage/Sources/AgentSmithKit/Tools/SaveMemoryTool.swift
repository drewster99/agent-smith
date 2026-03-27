import Foundation

/// Allows agents to save a piece of knowledge to the semantic memory store.
///
/// Available to both Smith and Brown. The calling agent's role determines the memory source.
public struct SaveMemoryTool: AgentTool {
    public let name = "save_memory"
    public let toolDescription = """
        Save a piece of information to long-term memory for future retrieval. \
        Use this when you discover something useful that would help with future tasks — \
        a pattern, a gotcha, a configuration detail, a user preference, a lesson learned. \
        Quality over quantity: only save genuinely useful insights, not routine observations.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "content": .dictionary([
                "type": .string("string"),
                "description": .string(
                    "The information to remember. Write clearly and specifically — " +
                    "this text will be used for semantic search matching in the future."
                )
            ]),
            "tags": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional categorization tags (e.g. 'debugging', 'user-preference', 'architecture').")
            ])
        ]),
        "required": .array([.string("content")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let content) = arguments["content"],
              !content.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolCallError.missingRequiredArgument("content")
        }

        var tags: [String] = []
        if case .array(let tagValues) = arguments["tags"] {
            for tagValue in tagValues {
                if case .string(let tag) = tagValue {
                    tags.append(tag)
                }
            }
        }

        let source: MemoryEntry.Source = switch context.agentRole {
        case .smith: .smith
        case .brown: .brown
        default: .user
        }

        // Determine the active task ID for context, if Brown is working on one.
        var sourceTaskID: UUID?
        if context.agentRole == .brown {
            if let task = await context.taskStore.taskForAgent(agentID: context.agentID) {
                sourceTaskID = task.id
            }
        }

        let entry = try await context.memoryStore.save(
            content: content,
            source: source,
            tags: tags,
            sourceTaskID: sourceTaskID
        )

        // Post a channel banner so memory saves are visible in the transcript.
        await context.channel.post(ChannelMessage(
            sender: .system,
            content: String(content.prefix(120)),
            metadata: [
                "messageKind": .string("memory_saved"),
                "memoryContent": .string(content),
                "memoryTags": .string(tags.joined(separator: ", ")),
                "memorySource": .string(source.rawValue)
            ]
        ))

        let tagText = tags.isEmpty ? "" : " [tags: \(tags.joined(separator: ", "))]"
        return "Memory saved (ID: \(entry.id)).\(tagText)"
    }
}
