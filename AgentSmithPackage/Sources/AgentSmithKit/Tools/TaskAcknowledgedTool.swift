import Foundation

/// Brown tool: acknowledges receipt of the assigned task, transitioning it to running.
public struct TaskAcknowledgedTool: AgentTool {
    public let name = "task_acknowledged"
    public let toolDescription = "Acknowledge your assigned task. Call this when you begin working on the task."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([:]),
        "required": .array([])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return "No active task assigned to you."
        }

        guard task.status.isRunnable || task.status == .running else {
            return "Task '\(task.title)' cannot be acknowledged in its current state (\(task.status.rawValue))."
        }

        // Bump the explicit ack counter and use its post-increment value to decide
        // whether this is a fresh ack (count == 1) or a continuation (count > 1).
        // This is reliable across respawns, rejections, and crash-recovery paths;
        // the previous `!task.updates.isEmpty` heuristic wrongly classified any
        // respawn where Brown never called `task_update` as a fresh ack.
        let newAckCount = await context.taskStore.incrementAcknowledgmentCount(id: task.id)
        let isContinuation = newAckCount > 1

        await context.taskStore.updateStatus(id: task.id, status: .running)

        // Notify Smith privately
        guard let smithID = await context.agentIDForRole(.smith) else {
            return "Task acknowledged: \(task.title)"
        }

        let content: String
        let messageKind: String
        if isContinuation {
            content = "Continuing task '\(task.title)' — working on revisions."
            messageKind = "task_continuing"
        } else {
            content = "Task '\(task.title)' acknowledged. Beginning work."
            messageKind = "task_acknowledged"
        }

        await context.channel.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: content,
            metadata: ["messageKind": .string(messageKind)]
        ))

        return isContinuation
            ? "Task continuing: \(task.title)"
            : "Task acknowledged: \(task.title)"
    }
}
