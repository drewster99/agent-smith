import Foundation

/// Allows Smith to create new tasks.
public struct CreateTaskTool: AgentTool {
    public let name = "create_task"
    public let toolDescription = "Create a new task, automatically spawn Brown+Jones, and send the task description as initial instructions. Brown starts working immediately — no need to call spawn_brown or message_brown."

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

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let title) = arguments["title"] else {
            throw ToolCallError.missingRequiredArgument("title")
        }
        guard case .string(let description) = arguments["description"] else {
            throw ToolCallError.missingRequiredArgument("description")
        }

        let fullDescription = description + "\n\nReport the detailed results to the user using `task_complete`."
        let task = await context.taskStore.addTask(title: title, description: fullDescription)

        await context.channel.post(ChannelMessage(
            sender: .system,
            content: title,
            metadata: [
                "messageKind": .string("task_created"),
                "taskID": .string(task.id.uuidString),
                "taskDescription": .string(description)
            ]
        ))

        // Auto-spawn Brown+Jones and assign to this task.
        guard let brownID = await context.spawnBrown() else {
            return "Task created: \(task.id) — \(title). ⚠️ Failed to spawn Brown — call spawn_brown(\(task.id)) manually."
        }

        await context.taskStore.assignAgent(taskID: task.id, agentID: brownID)

        // Send task instructions to Brown automatically.
        await context.channel.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: brownID,
            recipient: .agent(.brown),
            content: "Task: \(title)\n\n\(fullDescription)"
        ))

        return "Task created and Brown spawned. Task ID: \(task.id). Send any additional instructions via message_brown if needed."
    }
}
