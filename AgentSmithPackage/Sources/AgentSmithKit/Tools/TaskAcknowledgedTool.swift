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

        await context.taskStore.updateStatus(id: task.id, status: .running)

        // Notify Smith privately
        guard let smithID = await context.agentIDForRole(.smith) else {
            return "Task acknowledged: \(task.title)"
        }
        await context.channel.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: "Task '\(task.title)' acknowledged. Beginning work.",
            metadata: ["messageKind": .string("task_acknowledged")]
        ))

        return "Task acknowledged: \(task.title)"
    }
}
