import Foundation

/// Allows Smith to spawn a new Brown+Jones agent pair for task execution.
public struct SpawnBrownTool: AgentTool {
    public let name = "spawn_brown"
    public let toolDescription = "Spawn a new Brown agent (with a paired Jones monitor) to execute a task."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to assign to the new Brown agent.")
            ]),
            "instructions": .dictionary([
                "type": .string("string"),
                "description": .string("Specific instructions for the Brown agent.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("instructions")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskID) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard case .string(let instructions) = arguments["instructions"] else {
            throw ToolCallError.missingRequiredArgument("instructions")
        }

        guard let brownID = await context.spawnBrown(taskID, instructions) else {
            return "Failed to spawn Brown agent."
        }

        if let taskUUID = UUID(uuidString: taskID) {
            await context.taskStore.assignAgent(taskID: taskUUID, agentID: brownID)
            await context.taskStore.updateStatus(id: taskUUID, status: .running)
        }

        return "Brown agent spawned: \(brownID)"
    }
}
