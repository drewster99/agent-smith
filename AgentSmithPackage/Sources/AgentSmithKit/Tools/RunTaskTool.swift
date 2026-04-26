import Foundation

/// Allows Smith to run an existing pending, paused, interrupted, failed, or completed task
/// without duplicating it. When invoked on a failed or completed task, the task's terminal
/// state is reset (result, commentary, and completedAt are cleared and status returns to
/// `.pending`) before the run begins — the user said "try again" / "redo that" / "reopen
/// that" means "rerun on the same task ID", not "create a new one."
public struct RunTaskTool: AgentTool {
    public let name = "run_task"
    public let toolDescription = "Run an existing pending, paused, interrupted, failed, or completed task. Restarts with a clean context and auto-spawns Brown+Jones. Failed and completed tasks are auto-reset (prior result/commentary cleared, status flipped back to pending) before running — this is how you reopen a completed task without creating a duplicate. The `instructions` field is REQUIRED — include any updates, permissions, scope changes, or clarifications from the user. These are appended to the task description and survive the restart.\nIMPORTANT: Only one task can run at a time. Calling `run_task` will STOP any currently executing task."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the pending, paused, interrupted, failed, or completed task to run. Completed tasks are reopened (terminal state cleared) so the same id keeps its history.")
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

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Invalid task_id: '\(taskIDString)' is not a valid UUID. Use list_tasks to find valid task IDs.")
        }
        guard var task = await context.taskStore.task(id: taskID) else {
            return .failure("No task found with ID \(taskID). Use `list_tasks` to see available tasks.")
        }
        // Allow pending/paused/interrupted directly. For failed, reset the task back to
        // pending first so the retry runs on the same task ID (preserving history and prior
        // context). Completed tasks get the same reopen-in-place treatment so the user's
        // "redo that one" never silently turns into a new duplicate task.
        if task.status == .failed {
            _ = await context.taskStore.resetFailedTask(id: taskID)
            guard let refreshed = await context.taskStore.task(id: taskID), refreshed.status.isRunnable else {
                return .failure("Could not reset task '\(task.title)' for retry.")
            }
            task = refreshed
        } else if task.status == .completed {
            _ = await context.taskStore.reopenCompletedTask(id: taskID)
            guard let refreshed = await context.taskStore.task(id: taskID), refreshed.status.isRunnable else {
                return .failure("Could not reopen completed task '\(task.title)'.")
            }
            task = refreshed
        } else if !task.status.isRunnable {
            return .failure("""
                Task '\(task.title)' has status '\(task.status.rawValue)' — run_task only works on pending, paused, interrupted, failed, or completed tasks. \
                Use list_tasks to check current statuses, or create_task if you need a new task.
                """)
        }

        // Refuse to restart if another task is running or awaiting review.
        // Running: would kill Brown mid-work. AwaitingReview: Smith should review first.
        let allTasks = await context.taskStore.allTasks()
        if let runningTask = allTasks.first(where: { $0.status == .running && $0.id != taskID }) {
            return .failure("""
                Cannot start '\(task.title)' — task '\(runningTask.title)' is still running. \
                Wait for the current task to complete (or fail) before calling run_task. \
                The task has been created and is queued as pending.
                """)
        }
        if let reviewTask = allTasks.first(where: { $0.status == .awaitingReview && $0.id != taskID }) {
            return .failure("""
                Cannot start '\(task.title)' — task '\(reviewTask.title)' is awaiting your review. \
                Call review_work to accept or reject it first, then run_task to start the next task.
                """)
        }

        // Prevent restart loops: if the system *just* restarted for this exact task AND
        // Brown is still actively running it, don't restart again. After a pause/stop the
        // task's status drops out of `.running`, Brown is gone, and `currentResumingTaskID`
        // is stale — a legitimate resume must NOT be blocked by a stale flag, otherwise
        // Smith loops forever telling the user "Brown is auto-spawned" while nothing happens.
        if context.currentResumingTaskID == taskID, task.status == .running {
            return .failure("""
                The system has already restarted for this task and Brown is actively working on it. \
                Do NOT call run_task again. Brown will signal progress via task_update / task_complete; \
                you'll also receive an automatic 10-minute Brown-activity digest.
                """)
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

        return .success("Running task '\(task.title)' (ID: \(task.id)). System is restarting with a clean context to begin work.")
    }
}
