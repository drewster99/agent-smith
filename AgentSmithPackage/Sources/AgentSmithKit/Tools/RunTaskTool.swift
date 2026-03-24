import Foundation

/// Allows Smith to run an existing pending or paused task without duplicating it.
public struct RunTaskTool: AgentTool {
    public let name = "run_task"
    public let toolDescription = "Run an existing pending or paused task. Restarts with a clean context and auto-spawns Brown+Jones — no need to call spawn_brown or message_brown."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the pending or paused task to run.")
            ])
        ]),
        "required": .array([.string("task_id")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.hasPendingOrPausedTasks && context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task_id: '\(taskIDString)' is not a valid UUID. Use list_tasks to find valid task IDs."
        }
        guard let task = await context.taskStore.task(id: taskID) else {
            return "No task found with ID \(taskID). Use list_tasks to see available tasks."
        }
        guard task.status == .pending || task.status == .paused else {
            return """
                Task '\(task.title)' has status '\(task.status.rawValue)' — run_task only works on pending or paused tasks. \
                Use list_tasks to check current statuses, or create_task if you need a new task.
                """
        }

        await context.restartForNewTask(task.id)

        return "Running task '\(task.title)' (ID: \(task.id)). System is restarting with a clean context to begin work."
    }
}
