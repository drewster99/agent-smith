import Foundation

/// Allows agents to fetch full details of a specific task by ID.
public struct GetTaskDetailsTool: AgentTool {
    public let name = "get_task_details"
    public let toolDescription = "Fetch the full details of a task by its ID, including title, description, commentary, progress updates, and summary."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to fetch.")
            ])
        ]),
        "required": .array([.string("task_id")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        true
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            return "Missing required parameter: task_id"
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task_id: '\(taskIDString)' is not a valid UUID."
        }
        guard let task = await context.taskStore.task(id: taskID) else {
            return "No task found with ID \(taskID). Use list_tasks to see available tasks."
        }

        var parts: [String] = []
        parts.append("Title: \(task.title)")
        parts.append("Status: \(task.status.rawValue)")
        parts.append("Description: \(task.description)")

        if let commentary = task.commentary, !commentary.isEmpty {
            parts.append("Commentary: \(commentary)")
        }

        if !task.updates.isEmpty {
            let updateLines = task.updates.map { update in
                "  - [\(Self.formatDate(update.date))] \(update.message)"
            }
            parts.append("Progress updates:\n\(updateLines.joined(separator: "\n"))")
        }

        if let summary = task.summary, !summary.isEmpty {
            parts.append("Summary: \(summary)")
        }

        if let result = task.result, !result.isEmpty {
            parts.append("Result: \(result)")
        }

        return parts.joined(separator: "\n")
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
