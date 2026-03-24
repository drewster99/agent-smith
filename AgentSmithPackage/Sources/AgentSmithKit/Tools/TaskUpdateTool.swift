import Foundation

/// Brown tool: sends a progress update to Smith about the current task.
public struct TaskUpdateTool: AgentTool {
    public let name = "task_update"
    public let toolDescription = "Send a progress update to Smith about your current task. No status change occurs."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The progress update message.")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return "No active task assigned to you."
        }

        // Persist on the task so it survives restarts.
        await context.taskStore.addUpdate(id: task.id, message: message)

        guard let smithID = await context.agentIDForRole(.smith) else {
            return "Agent Smith is not available."
        }

        await context.channel.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: "Task update for '\(task.title)': \(message)"
        ))

        return "Update sent to Agent Smith."
    }
}
