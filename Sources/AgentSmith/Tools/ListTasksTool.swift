import Foundation

/// Allows Smith to list all tasks and their statuses.
public struct ListTasksTool: AgentTool {
    public let name = "list_tasks"
    public let toolDescription = "List all tasks with their current status, title, and description."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "status_filter": .dictionary([
                "type": .string("string"),
                "description": .string("Optional filter: 'pending', 'running', 'completed', or 'failed'. Omit to list all tasks."),
                "enum": .array([.string("pending"), .string("running"), .string("completed"), .string("failed")])
            ])
        ]),
        "required": .array([])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        var tasks = await context.taskStore.allTasks()

        if case .string(let filterValue) = arguments["status_filter"],
           let status = AgentTask.Status(rawValue: filterValue) {
            tasks = tasks.filter { $0.status == status }
        }

        guard !tasks.isEmpty else {
            return "No tasks found."
        }

        let lines = tasks.map { task in
            "[\(task.status.rawValue.uppercased())] \(task.title) (id: \(task.id.uuidString))\n  \(task.description)"
        }
        return "\(tasks.count) task(s):\n\(lines.joined(separator: "\n"))"
    }
}
