import Foundation

/// Smith tool: lists all currently-scheduled wakes (id, time, reason, task association).
/// Use before `schedule_wake` to check for duplicates and resolve conflicts.
public struct ListScheduledWakesTool: AgentTool {
    public let name = "list_scheduled_wakes"
    public let toolDescription = """
        List every scheduled wake currently registered (id, time, reason, optional task_id). \
        Call this before `schedule_wake` to check for duplicates or to find an existing wake's \
        id when the user asks to cancel or change one. Read-only.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([:]),
        "required": .array([])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        let wakes = await context.listScheduledWakes()
        guard !wakes.isEmpty else {
            return .success("No wakes currently scheduled.")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lines = wakes.map { wake -> String in
            let taskFragment = wake.taskID.map { " task=\($0.uuidString)" } ?? ""
            return "  • id=\(wake.id.uuidString) at=\(formatter.string(from: wake.wakeAt))\(taskFragment) reason=\"\(wake.reason)\""
        }
        return .success("Scheduled wakes (\(wakes.count)):\n\(lines.joined(separator: "\n"))")
    }
}
