import Foundation

/// Allows Smith to run an existing pending, paused, interrupted, or failed task without
/// duplicating it. When invoked on a failed task, the task's terminal state is reset (result,
/// commentary, and completedAt are cleared and status returns to `.pending`) before the run
/// begins — the user said "try again" means "rerun on the same task ID", not "create a new one."
public struct RunTaskTool: AgentTool {
    public let name = "run_task"
    public let toolDescription = "Run an existing pending, paused, interrupted, or failed task. Restarts with a clean context and auto-spawns Brown+Jones. Failed tasks are reset (prior result/commentary cleared) before running. The `instructions` field is REQUIRED — include any updates, permissions, scope changes, or clarifications from the user. These are appended to the task description and survive the restart.\nIMPORTANT: Only one task can run at a time. Calling `run_task` will STOP any currently executing task."

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
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task_id: '\(taskIDString)' is not a valid UUID. Use list_tasks to find valid task IDs."
        }
        guard var task = await context.taskStore.task(id: taskID) else {
            return "No task found with ID \(taskID). Use `list_tasks` to see available tasks."
        }
        // Allow pending/paused/interrupted directly. For failed, reset the task back to pending
        // first so the retry runs on the same task ID (preserving history and prior context).
        if task.status == .failed {
            _ = await context.taskStore.resetFailedTask(id: taskID)
            // Re-fetch the now-reset task for the rest of this method.
            guard let refreshed = await context.taskStore.task(id: taskID), refreshed.status.isRunnable else {
                return "Could not reset task '\(task.title)' for retry."
            }
            task = refreshed
        } else if !task.status.isRunnable {
            return """
                Task '\(task.title)' has status '\(task.status.rawValue)' — run_task only works on pending, paused, interrupted, or failed tasks. \
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
                The system has already restarted for this task and Brown has been auto-spawned. \
                Do NOT call run_task again. Brown will signal progress via task_update / task_complete; \
                you'll also receive an automatic 10-minute Brown-activity digest.
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
