import Foundation

/// Allows Smith to spawn a new Brown+Jones agent pair for an existing task.
public struct SpawnBrownTool: AgentTool {
    public let name = "spawn_brown"
    public let toolDescription = "Re-spawn a Brown+Jones agent pair for an existing task (e.g., after termination or if auto-spawn failed during create_task). Not needed for new tasks — create_task handles spawning automatically. Returns the Brown agent's ID. Send task instructions via message_brown after spawning."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the task to assign this Brown agent to.")
            ])
        ]),
        "required": .array([.string("task_id")])
    ]

    private static let updateDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid `task_id`: '\(taskIDString)' is not a valid UUID. Use list_tasks to find valid task IDs."
        }
        guard let task = await context.taskStore.task(id: taskID) else {
            return "No task found with ID \(taskID). Use list_tasks to see available tasks."
        }

        let runnableStatuses: Set<AgentTask.Status> = [.pending, .running, .paused]
        guard runnableStatuses.contains(task.status) else {
            return "Task '\(task.title)' has status '\(task.status.rawValue)' — `spawn_brown` requires a pending, running, or paused task. Use `create_task` for new work."
        }

        // Check that no active Brown is already assigned
        for assigneeID in task.assigneeIDs {
            if let role = await context.agentRoleForID(assigneeID), role == .brown {
                return "A Brown agent is already assigned to this task. Use `schedule_followup` to check back later, or terminate the existing Brown first."
            }
        }

        guard let brownID = await context.spawnBrown() else {
            return "Failed to spawn Brown agent."
        }

        await context.taskStore.assignAgent(taskID: taskID, agentID: brownID)

        var response = "Brown agent spawned: \(brownID). Send it task instructions via `message_brown`."
        if !task.updates.isEmpty {
            let history = task.updates.map { entry in
                "[\(Self.updateDateFormatter.string(from: entry.date))] \(entry.message)"
            }.joined(separator: "\n")
            response += "\n\nPrevious progress updates from the prior Brown agent:\n\(history)"
            response += "\n\nInclude this history in your message_brown so the new Brown knows where the previous one left off."
        }
        return response
    }
}
