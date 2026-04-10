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

        // Post Brown's update as clean content — no system guidance embedded in it,
        // so Brown cannot craft text that manipulates the guidance via prompt injection.
        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: "Task update for '\(task.title)': \(message)",
            metadata: ["messageKind": .string("task_update")]
        ))

        // Post guidance as a separate system message so it cannot be influenced by Brown's text.
        await context.post(ChannelMessage(
            sender: .system,
            recipientID: smithID,
            recipient: .agent(.smith),
            content: "Scrutinize Brown's task update above CAREFULLY in the context of the user's intent AND the task description and details. Make sure Brown is on track and hasn't veered off course. Offer assistance or helpful suggestions if Brown appears to NEED it. DO NOT REPLY if do not have MEANINGFUL input to add. The user ALREADY SEES Brown's task update directly in the channel — DO NOT repeat, summarize, paraphrase, or relay Brown's update to the user via message_user. Doing so is duplicative noise.",
            metadata: ["messageKind": .string("task_update_guidance")]
        ))

        return "Update sent to Agent Smith."
    }
}
