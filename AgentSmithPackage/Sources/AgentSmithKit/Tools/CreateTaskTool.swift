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

        await context.channel.post(ChannelMessage(
            sender: .system,
            content: title,
            metadata: [
                "messageKind": .string("task_created"),
                "taskID": .string(task.id.uuidString),
                "taskDescription": .string(description)
            ]
        ))

        return "Task created (ID: \(task.id), title: \"\(title)\"). Call `run_task` with this task ID to start it."
    }
}
