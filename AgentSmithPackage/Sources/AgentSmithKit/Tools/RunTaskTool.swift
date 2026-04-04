import Foundation

/// Allows Smith to run an existing pending or paused task without duplicating it.
public struct RunTaskTool: AgentTool {
    public let name = "run_task"
    public let toolDescription = "Run an existing pending or paused task. Restarts with a clean context and auto-spawns Brown+Jones. The `instructions` field is REQUIRED — include any updates, permissions, scope changes, or clarifications from the user. These are appended to the task description and survive the restart."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the pending or paused task to run.")
            ]),
            "instructions": .dictionary([
                "type": .string("string"),
                "description": .string("Instructions to append to the task description. Include any new permissions, scope changes, or clarifications from the user. If the user said nothing new, summarize their confirmation (e.g. 'User confirmed: proceed as described'). These survive the restart and are visible to Brown and Jones.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("instructions")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.hasPendingOrPausedTasks && context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task_id: '\(taskIDString)' is not a valid UUID. Use list_tasks to find valid task IDs."
        }
        guard let task = await context.taskStore.task(id: taskID) else {
            return "No task found with ID \(taskID). Use `list_tasks` to see available tasks."
        }
        guard task.status == .pending || task.status == .paused else {
            return """
                Task '\(task.title)' has status '\(task.status.rawValue)' — run_task only works on pending or paused tasks. \
                Use list_tasks to check current statuses, or create_task if you need a new task.
                """
        }

        // Refuse to restart if another task is running or awaiting review.
        // Running: would kill Brown mid-work. AwaitingReview: Smith should review first.
        let allTasks = await context.taskStore.allTasks()
        if let runningTask = allTasks.first(where: { $0.status == .running && $0.id != taskID }) {
            return """
                Cannot start '\(task.title)' — task '\(runningTask.title)' is still running. \
                Wait for the current task to complete (or fail) before calling run_task. \
                The task has been created and is queued as pending.
                """
        }
        if let reviewTask = allTasks.first(where: { $0.status == .awaitingReview && $0.id != taskID }) {
            return """
                Cannot start '\(task.title)' — task '\(reviewTask.title)' is awaiting your review. \
                Call review_work to accept or reject it first, then run_task to start the next task.
                """
        }

        // Prevent restart loops: if the system already restarted for this exact task,
        // don't restart again — just tell Smith to spawn Brown directly.
        if context.currentResumingTaskID == taskID {
            return """
                The system has already restarted for this task. Do NOT call run_task again. \
                Call `spawn_brown` now to start a Brown agent, then use `message_brown` to give it the task instructions.
                """
        }

        guard case .string(let instructions) = arguments["instructions"] else {
            throw ToolCallError.missingRequiredArgument("instructions")
        }

        // Amend the task with the instructions before restarting, so they survive
        // the context reset and are visible to the new Smith, Brown, and Jones.
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            await context.taskStore.amendDescription(id: taskID, amendment: trimmed)
        }

        await context.restartForNewTask(task.id)

        return "Running task '\(task.title)' (ID: \(task.id)). System is restarting with a clean context to begin work."
    }
}
