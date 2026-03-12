import Foundation

/// Allows Smith to update a task's status.
public struct UpdateTaskTool: AgentTool {
    public let name = "update_task"
    public let toolDescription = "Update the status of an existing task."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to update.")
            ]),
            "status": .dictionary([
                "type": .string("string"),
                "enum": .array([
                    .string("pending"),
                    .string("running"),
                    .string("completed"),
                    .string("failed")
                ]),
                "description": .string("The new status for the task.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("status")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task ID format: \(taskIDString)"
        }
        guard case .string(let statusString) = arguments["status"] else {
            throw ToolCallError.missingRequiredArgument("status")
        }
        guard let status = AgentTask.Status(rawValue: statusString) else {
            return "Invalid status: \(statusString). Valid values: pending, running, completed, failed"
        }

        await context.taskStore.updateStatus(id: taskID, status: status)
        return "Task \(taskIDString) updated to \(statusString)."
    }
}
