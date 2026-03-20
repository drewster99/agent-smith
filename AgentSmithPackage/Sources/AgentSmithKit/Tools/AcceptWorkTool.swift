import Foundation

/// Smith tool: accepts Brown's completed work, marks the task as completed, and terminates the assigned agents.
public struct AcceptWorkTool: AgentTool {
    public let name = "accept_work"
    public let toolDescription = """
        Accept Brown's completed work on a task. Marks the task as completed and automatically \
        terminates Brown and Jones agents assigned to it.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to accept.")
            ])
        ]),
        "required": .array([.string("task_id")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task ID format: \(taskIDString)"
        }

        guard let task = await context.taskStore.task(id: taskID) else {
            return "Task not found: \(taskIDString)"
        }

        guard task.status == .awaitingReview else {
            return "Task '\(task.title)' is not awaiting review (current status: \(task.status.rawValue))."
        }

        await context.taskStore.updateStatus(id: taskID, status: .completed)

        // Terminate all agents assigned to this task
        for agentID in task.assigneeIDs {
            _ = await context.terminateAgent(agentID, context.agentID)
        }

        await context.channel.post(ChannelMessage(
            sender: .system,
            content: "Task '\(task.title)' completed. Assigned agents terminated."
        ))

        return "Task accepted and agents terminated."
    }
}
