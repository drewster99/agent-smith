import Foundation

/// Smith tool: reviews Brown's submitted work, either accepting or requesting changes.
/// Merges AcceptWorkTool and RequestChangesTool into a single decision point.
public struct ReviewWorkTool: AgentTool {
    public let name = "review_work"
    public let toolDescription = """
        Review Brown's submitted work on a task (must be in awaitingReview status). \
        Set `accepted` to `true` to mark the task completed and terminate Brown + Jones. \
        Set `accepted` to `false` to return the task to running and send feedback to Brown. \
        `feedback` is required when `accepted` is `false`.
        
        To perform your review:
        1. Call `get_task_details` to see the current and latest task description, progress and details
        2. Carefully step through every requirement described in the task. For each requirement, review the work submitted by Agent Brown to determine if the requirement has been satisfied. If necessary, call `file_read` to validate the results. Be sure that each requirement is not only satisfied, but has been satisfied in the best most complete way possible.
        3. Compile a list of ALL potential deficiencies in the submitted work.
        4. Re-check the task details again and look for key points that could have been misinterpreted or easily missed. Double check those items are complete.
        5. If you have previously rejected submitted work, review your earlier rejection response. Anything you rejected previously must be resolved and any questions or concerns expressed in your earlier rejection must be addressed.
        5. If there are ANY identified deficiencies OR any unaddressed questions OR any concerns, then you MUST REJECT the work, by calling `review_work` with `accepted` = `false`. Include your complete and detailed feedback in the `feedback` field. The feedback must include ALL items identified in any of the steps above, including any outstanding issues from prior rejections you may have sent.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to review.")
            ]),
            "accepted": .dictionary([
                "type": .string("boolean"),
                "description": .string(
                    "true = accept the work, complete the task, and terminate Brown. " +
                    "false = reject the work and return it to Brown for revision."
                )
            ]),
            "feedback": .dictionary([
                "type": .string("string"),
                "description": .string(
                    "Required when accepted is false. " +
                    "Be specific: explain exactly what is wrong and what needs to change."
                )
            ])
        ]),
        "required": .array([.string("task_id"), .string("accepted")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith && context.hasAwaitingReviewTasks
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Invalid task ID format: \(taskIDString)")
        }

        guard let accepted = resolveBool(arguments["accepted"]) else {
            throw ToolCallError.missingRequiredArgument("accepted")
        }

        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("Task not found: \(taskIDString)")
        }

        guard task.status == .awaitingReview else {
            return .failure("""
                Task '\(task.title)' is not awaiting review (current status: \(task.status.rawValue)). \
                `review_work` can only be called after Brown submits via `task_complete`.
                """)
        }

        if accepted {
            // ---- Accept path ----
            await context.taskStore.updateStatus(id: taskID, status: .completed)

            // Fetch the updated task to get completedAt/startedAt timestamps.
            let completedTask = await context.taskStore.task(id: taskID) ?? task

            for agentID in completedTask.assigneeIDs {
                _ = await context.terminateAgent(agentID, context.agentID)
            }

            // Post a structured completion banner for the channel log.
            var bannerMetadata: [String: AnyCodable] = [
                "messageKind": .string("task_completed"),
                "taskID": .string(taskID.uuidString)
            ]
            if let startedAt = completedTask.startedAt, let completedAt = completedTask.completedAt {
                bannerMetadata["durationSeconds"] = .double(completedAt.timeIntervalSince(startedAt))
            }
            await context.post(ChannelMessage(
                sender: .system,
                content: completedTask.title,
                metadata: bannerMetadata
            ))

            // Deliver Brown's result directly to the user as a Smith message.
            if let result = completedTask.result, !result.isEmpty {
                await context.post(ChannelMessage(
                    sender: .agent(context.agentRole),
                    recipientID: OrchestrationRuntime.userID,
                    recipient: .user,
                    content: result
                ))
            }

            // Trigger background summarization and embedding of the completed task.
            await context.summarizeCompletedTask(taskID)

            return .success("Task '\(completedTask.title)' accepted and marked COMPLETE. Agents terminated. Result ALREADY delivered to user (do not deliver it again yourself, Agent Smith). **STOP** — your turn ends here. Do not call message_user, run_task, list_tasks, or any other tool. The system handles what happens next.")
        } else {
            // ---- Reject path ----
            let feedback: String
            if case .string(let f) = arguments["feedback"], !f.trimmingCharacters(in: .whitespaces).isEmpty {
                feedback = f
            } else {
                return .failure("`feedback` is required when `accepted` is `false`. Provide specific details about what needs to change.")
            }

            await context.taskStore.updateStatus(id: taskID, status: .running)
            await context.taskStore.clearResult(id: taskID)

            // Find an existing Brown, or auto-spawn one if needed (e.g. after app restart)
            var brownID: UUID?
            var brownWasSpawned = false
            for agentID in task.assigneeIDs {
                if let role = await context.agentRoleForID(agentID), role == .brown {
                    brownID = agentID
                    break
                }
            }

            if brownID == nil {
                if let newBrownID = await context.spawnBrown() {
                    await context.taskStore.assignAgent(taskID: taskID, agentID: newBrownID)
                    brownID = newBrownID
                    brownWasSpawned = true
                }
            }

            guard let brownID else {
                return .failure("Task returned to running, but failed to spawn a Brown agent. Check provider configuration.")
            }

            let content: String
            if brownWasSpawned {
                // New Brown needs full context — it has no prior conversation history
                var messageParts: [String] = []
                let currentTask = await context.taskStore.task(id: taskID) ?? task
                messageParts.append("## Task: \(currentTask.title)\n\n\(currentTask.description)")

                if !currentTask.updates.isEmpty {
                    let history = currentTask.updates.map { "- \($0.message)" }.joined(separator: "\n")
                    messageParts.append("## Prior Progress\n\(history)")
                }

                messageParts.append("## Changes Required\n\(feedback)")
                content = messageParts.joined(separator: "\n\n")
            } else {
                // Existing Brown already has context — just send the rejection feedback
                content = "Results rejected - changes required on task '\(task.title)': \(feedback)"
            }

            await context.post(ChannelMessage(
                sender: .agent(context.agentRole),
                recipientID: brownID,
                recipient: .agent(.brown),
                content: content,
                metadata: [
                    "messageKind": .string("changes_requested"),
                    "taskTitle": .string(task.title)
                ]
            ))

            return .success(brownWasSpawned
                ? "Changes requested. A new Brown has been spawned and briefed with the full task context and your feedback."
                : "Changes requested. Feedback sent to Brown.")
        }
    }

    // MARK: - Private

    /// Resolves a boolean from AnyCodable, tolerating .bool, .int (0/1), and string "true"/"false".
    /// This makes the tool robust regardless of how the LLM serializes the boolean parameter.
    private func resolveBool(_ value: AnyCodable?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let b):
            return b
        case .int(let i):
            if i == 1 { return true }
            if i == 0 { return false }
            return nil
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1":  return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}
