import Foundation

/// Allows agents to save a piece of knowledge to the semantic memory store.
///
/// Available to both Smith and Brown. The calling agent's role determines the memory source.
/// Automatically checks for semantically similar existing memories and consolidates
/// via LLM merge when a close match is found.
public struct SaveMemoryTool: AgentTool {
    public let name = "save_memory"
    public let toolDescription = """
        Save a piece of information to long-term memory for future retrieval. \
        Use this when you discover something useful that would help with future tasks — \
        a pattern, a gotcha, a configuration detail, a user preference, a lesson learned. \
        Quality over quantity: only save genuinely useful insights, not routine observations. \
        If a closely related memory already exists, it will be automatically consolidated.
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

    /// Minimum cosine similarity to consider two memories as candidates for consolidation.
    private static let consolidationThreshold: Float = 0.70

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

        // Search for semantically similar existing memories to consolidate.
        let similarMemories: [MemorySearchResult]
        do {
            similarMemories = try await context.memoryStore.searchMemories(
                query: content,
                limit: 1,
                threshold: Self.consolidationThreshold
            )
        } catch {
            // If search fails, proceed with normal save.
            similarMemories = []
        }

        if let match = similarMemories.first {
            // Attempt LLM-based merge of the existing and new content.
            if let merged = await context.mergeMemoryContent(match.memory.content, content) {
                let mergedTags = Array(Set(match.memory.tags + tags))
                do {
                    try await context.memoryStore.update(
                        id: match.memory.id,
                        content: merged,
                        tags: mergedTags
                    )
                } catch {
                    // If update fails, fall through to normal save.
                    return try await saveNew(
                        content: content, source: source, tags: tags,
                        sourceTaskID: sourceTaskID, consolidated: false, context: context
                    )
                }

                await postChannelMessage(
                    content: merged, tags: mergedTags, source: source,
                    consolidated: true, context: context
                )

                let tagText = mergedTags.isEmpty ? "" : " [tags: \(mergedTags.joined(separator: ", "))]"
                return "Consolidated into existing memory (ID: \(match.memory.id)).\(tagText)"
            }
        }

        // No match found or merge unavailable — save as new memory.
        return try await saveNew(
            content: content, source: source, tags: tags,
            sourceTaskID: sourceTaskID, consolidated: false, context: context
        )
    }

    // MARK: - Private

    private func saveNew(
        content: String,
        source: MemoryEntry.Source,
        tags: [String],
        sourceTaskID: UUID?,
        consolidated: Bool,
        context: ToolContext
    ) async throws -> String {
        let entry = try await context.memoryStore.save(
            content: content,
            source: source,
            tags: tags,
            sourceTaskID: sourceTaskID
        )

        await postChannelMessage(
            content: content, tags: tags, source: source,
            consolidated: false, context: context
        )

        let tagText = tags.isEmpty ? "" : " [tags: \(tags.joined(separator: ", "))]"
        return "Memory saved (ID: \(entry.id)).\(tagText)"
    }

    private func postChannelMessage(
        content: String,
        tags: [String],
        source: MemoryEntry.Source,
        consolidated: Bool,
        context: ToolContext
    ) async {
        await context.channel.post(ChannelMessage(
            sender: .system,
            content: String(content.prefix(120)),
            metadata: [
                "messageKind": .string("memory_saved"),
                "memoryContent": .string(content),
                "memoryTags": .string(tags.joined(separator: ", ")),
                "memorySource": .string(source.rawValue),
                "consolidated": .bool(consolidated)
            ]
        ))
    }
}
