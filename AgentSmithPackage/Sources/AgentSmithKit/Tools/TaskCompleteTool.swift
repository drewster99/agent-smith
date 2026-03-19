import Foundation

/// Brown tool: submits the task result for Smith's review, transitioning it to awaitingReview.
public struct TaskCompleteTool: AgentTool {
    public let name = "task_complete"
    public let toolDescription = """
        Submit your completed work for review. Provide the full result — do not summarize. \
        After calling this, stop working and wait for Smith's verdict.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "result": .dictionary([
                "type": .string("string"),
                "description": .string("The full result of your work. Include everything relevant — do not summarize.")
            ]),
            "commentary": .dictionary([
                "type": .string("string"),
                "description": .string("Optional commentary about approach, caveats, or notes for Smith.")
            ])
        ]),
        "required": .array([.string("result")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let result) = arguments["result"] else {
            throw ToolCallError.missingRequiredArgument("result")
        }

        let commentary: String?
        if case .string(let c) = arguments["commentary"] {
            commentary = c
        } else {
            commentary = nil
        }

        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return "No active task assigned to you."
        }

        // Idempotency guard
        if task.status == .awaitingReview || task.status == .completed {
            return "Task already submitted for review."
        }

        // Store result on the task (survives restarts) and transition status
        await context.taskStore.setResult(id: task.id, result: result, commentary: commentary)
        await context.taskStore.updateStatus(id: task.id, status: .awaitingReview)

        // Notify Smith privately
        guard let smithID = await context.agentIDForRole(.smith) else {
            return "Task submitted for review: \(task.title)"
        }

        var message = "Task '\(task.title)' is ready for review.\n\nResult:\n\(result)"
        if let commentary {
            message += "\n\nCommentary:\n\(commentary)"
        }

        await context.channel.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: message
        ))

        return "Task submitted for review: \(task.title)"
    }
}
