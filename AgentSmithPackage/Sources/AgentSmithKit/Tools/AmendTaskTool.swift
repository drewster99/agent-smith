import Foundation

/// Allows Smith to amend a task's description with additional context from the user.
///
/// Amendments are appended to the task description with a clear label, so both
/// Brown (via `message_brown`) and Jones (who reads `taskDescription` on every
/// tool-approval request) see the updated intent.
public struct AmendTaskTool: AgentTool {
    public let name = "amend_task"
    public let toolDescription = "Append a clarification or updated instruction to a task's description. Use this when the user provides new context, corrections, or additional requirements for an in-progress task. The amendment is visible to Jones (security) and should also be relayed to Brown via `message_brown`."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to amend.")
            ]),
            "amendment": .dictionary([
                "type": .string("string"),
                "description": .string("The clarification or updated instruction to append to the task description.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("amendment")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task ID format: \(taskIDString)"
        }
        guard case .string(let amendment) = arguments["amendment"] else {
            throw ToolCallError.missingRequiredArgument("amendment")
        }
        guard let trimmed = Optional(amendment.trimmingCharacters(in: .whitespacesAndNewlines)),
              !trimmed.isEmpty else {
            return "Error: amendment must not be empty."
        }

        guard await context.taskStore.task(id: taskID) != nil else {
            return "Task not found: \(taskIDString)"
        }

        await context.taskStore.amendDescription(id: taskID, amendment: trimmed)
        return "Task \(taskIDString) amended. Immediately use the `message_brown` tool to relay this change to Brown."
    }
}
