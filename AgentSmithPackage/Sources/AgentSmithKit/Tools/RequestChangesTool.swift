import Foundation

/// Smith tool: requests changes to Brown's submitted work, returning the task to running status.
public struct RequestChangesTool: AgentTool {
    public let name = "request_changes"
    public let toolDescription = """
        Request changes to Brown's submitted work. Returns the task to running status and sends \
        feedback to Brown so it can continue working.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to request changes on.")
            ]),
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("Feedback explaining what changes are needed.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("message")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task ID format: \(taskIDString)"
        }
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        guard let task = await context.taskStore.task(id: taskID) else {
            return "Task not found: \(taskIDString)"
        }

        guard task.status == .awaitingReview else {
            return "Task '\(task.title)' is not awaiting review (current status: \(task.status.rawValue))."
        }

        // Return task to running and clear stored result
        await context.taskStore.updateStatus(id: taskID, status: .running)
        await context.taskStore.clearResult(id: taskID)

        // Find Brown's UUID from the task's assignees
        var sent = false
        for agentID in task.assigneeIDs {
            if let role = await context.agentRoleForID(agentID), role == .brown {
                await context.channel.post(ChannelMessage(
                    sender: .agent(context.agentRole),
                    recipientID: agentID,
                    recipient: .agent(.brown),
                    content: "Changes requested on task '\(task.title)': \(message)"
                ))
                sent = true
                break
            }
        }

        if !sent {
            return "Task returned to running, but no active Brown agent found to notify. You may need to spawn a new Brown."
        }

        return "Changes requested. Message sent to Brown."
    }
}
