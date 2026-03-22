import Foundation

/// Allows Smith to spawn a new Brown+Jones agent pair.
public struct SpawnBrownTool: AgentTool {
    public let name = "spawn_brown"
    public let toolDescription = "Spawn a new Brown agent (a Jones data archival agent starts alongside it automatically). Returns the Brown agent's ID. Send task instructions separately via message_brown. Optionally provide a task_id to associate the spawned agent with a task."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("Optional UUID of the task to assign this Brown agent to.")
            ])
        ]),
        "required": .array([])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        // If a task_id is provided, check that no active Brown is already assigned to it
        if case .string(let taskIDString) = arguments["task_id"],
           let taskID = UUID(uuidString: taskIDString) {
            if let task = await context.taskStore.task(id: taskID) {
                let activeStatuses: Set<AgentTask.Status> = [.pending, .running, .paused, .awaitingReview]
                if activeStatuses.contains(task.status) {
                    for assigneeID in task.assigneeIDs {
                        if let role = await context.agentRoleForID(assigneeID), role == .brown {
                            return "A Brown agent is already assigned to this task. Use schedule_followup to check back later, or terminate the existing Brown first."
                        }
                    }
                }
            }
        }

        guard let brownID = await context.spawnBrown() else {
            return "Failed to spawn Brown agent."
        }

        if case .string(let taskIDString) = arguments["task_id"],
           let taskID = UUID(uuidString: taskIDString) {
            await context.taskStore.assignAgent(taskID: taskID, agentID: brownID)
        }

        return "Brown agent spawned: \(brownID). Send it task instructions via message_brown."
    }
}
