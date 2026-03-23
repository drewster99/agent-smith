import Foundation

/// Allows Smith to create new tasks.
public struct CreateTaskTool: AgentTool {
    public let name = "create_task"
    public let toolDescription = "Create a new task and restart the system with a clean context. Brown will be spawned automatically on restart — no need to call spawn_brown or message_brown."

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

        // Trigger a full system restart so Smith gets a clean conversation context.
        // The detached restart will call stopAll() then start(resumingTaskID:), which
        // auto-spawns Brown with this task. Smith's current run loop will exit cleanly
        // when stop() sets isRunning = false.
        await context.restartForNewTask(task.id)

        return "Task created (ID: \(task.id)). System is restarting with a clean context to begin work."
    }
}
