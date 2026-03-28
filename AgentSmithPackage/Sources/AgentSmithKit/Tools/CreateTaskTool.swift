import Foundation

/// Allows Smith to create new tasks.
///
/// Always creates the task as pending. Smith must call `run_task` to start it.
public struct CreateTaskTool: AgentTool {
    public let name = "create_task"
    public let toolDescription = "Create a new pending task. The task is always queued — call `run_task` to start it when ready. You can create multiple tasks before running any of them."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "title": .dictionary([
                "type": .string("string"),
                "description": .string("Short title for the task.")
            ]),
            "description": .dictionary([
                "type": .string("string"),
                "description": .string("Detailed description of what needs to be done.")
            ])
        ]),
        "required": .array([.string("title"), .string("description")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let title) = arguments["title"] else {
            throw ToolCallError.missingRequiredArgument("title")
        }
        guard case .string(let description) = arguments["description"] else {
            throw ToolCallError.missingRequiredArgument("description")
        }

        let task = await context.taskStore.addTask(title: title, description: description)

        // Search semantic memory for relevant context to attach to this task.
        let searchQuery = title + " " + description
        var contextNote = ""
        do {
            let results = try await context.memoryStore.searchAll(
                query: searchQuery,
                memoryLimit: 3,
                taskLimit: 3
            )
            if !results.isEmpty {
                let memories: [RelevantMemory]? = results.memories.isEmpty ? nil : results.memories.map {
                    RelevantMemory(content: $0.memory.content, tags: $0.memory.tags, similarity: $0.similarity)
                }
                let priorTasks: [RelevantPriorTask]? = results.taskSummaries.isEmpty ? nil : results.taskSummaries.map {
                    RelevantPriorTask(taskID: $0.summary.id, title: $0.summary.title, summary: $0.summary.summary, similarity: $0.similarity)
                }
                await context.taskStore.setRelevantContext(
                    id: task.id,
                    memories: memories,
                    priorTasks: priorTasks
                )

                var parts: [String] = []
                if let memories, !memories.isEmpty {
                    parts.append("\(memories.count) relevant memor\(memories.count == 1 ? "y" : "ies")")
                }
                if let priorTasks, !priorTasks.isEmpty {
                    parts.append("\(priorTasks.count) relevant prior task\(priorTasks.count == 1 ? "" : "s")")
                }
                if !parts.isEmpty {
                    contextNote = " Attached: \(parts.joined(separator: ", "))."
                }
            }
        } catch {
            // Memory search failure is non-fatal — task still gets created.
        }

        // Build metadata for the task_created channel message, including any retrieved context.
        var meta: [String: AnyCodable] = [
            "messageKind": .string("task_created"),
            "taskID": .string(task.id.uuidString),
            "taskDescription": .string(description)
        ]
        if let task = await context.taskStore.task(id: task.id) {
            if let memories = task.relevantMemories, !memories.isEmpty {
                meta["contextMemoryCount"] = .int(memories.count)
                meta["contextMemories"] = .string(memories.map { m in
                    let pct = String(format: "%.0f%%", m.similarity * 100)
                    let tags = m.tags.isEmpty ? "" : " [\(m.tags.joined(separator: ", "))]"
                    return "\(pct) — \(m.content)\(tags)"
                }.joined(separator: "\n"))
            }
            if let priorTasks = task.relevantPriorTasks, !priorTasks.isEmpty {
                meta["contextPriorTaskCount"] = .int(priorTasks.count)
                meta["contextPriorTasks"] = .string(priorTasks.map { p in
                    let pct = String(format: "%.0f%%", p.similarity * 100)
                    return "\(pct) — \(p.title): \(p.summary)"
                }.joined(separator: "\n"))
            }
        }

        await context.channel.post(ChannelMessage(
            sender: .system,
            content: title,
            metadata: meta
        ))

        return "Task created (ID: \(task.id), title: \"\(title)\").\(contextNote) Call `run_task` with this task ID to start it."
    }
}
