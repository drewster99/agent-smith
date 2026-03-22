import Foundation

/// Smith tool: reviews Brown's submitted work, either accepting or requesting changes.
/// Merges AcceptWorkTool and RequestChangesTool into a single decision point.
public struct ReviewWorkTool: AgentTool {
    public let name = "review_work"
    public let toolDescription = """
        Review Brown's submitted work on a task (must be in awaitingReview status). \
        Set accepted to true to mark the task completed and terminate Brown + Jones. \
        Set accepted to false to return the task to running and send feedback to Brown. \
        feedback is required when accepted is false.
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

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return "Invalid task ID format: \(taskIDString)"
        }

        guard let accepted = resolveBool(arguments["accepted"]) else {
            throw ToolCallError.missingRequiredArgument("accepted")
        }

        guard let task = await context.taskStore.task(id: taskID) else {
            return "Task not found: \(taskIDString)"
        }

        guard task.status == .awaitingReview else {
            return """
                Task '\(task.title)' is not awaiting review (current status: \(task.status.rawValue)). \
                review_work can only be called after Brown submits via task_complete.
                """
        }

        if accepted {
            // ---- Accept path ----
            await context.taskStore.updateStatus(id: taskID, status: .completed)

            for agentID in task.assigneeIDs {
                _ = await context.terminateAgent(agentID, context.agentID)
            }

            await context.channel.post(ChannelMessage(
                sender: .system,
                content: "Task '\(task.title)' accepted and completed. Assigned agents terminated."
            ))

            return """
                Task '\(task.title)' accepted and completed. Agents terminated. \
                Now send the user the result using message_user.
                """
        } else {
            // ---- Reject path ----
            let feedback: String
            if case .string(let f) = arguments["feedback"], !f.trimmingCharacters(in: .whitespaces).isEmpty {
                feedback = f
            } else {
                return "feedback is required when accepted is false. Provide specific details about what needs to change."
            }

            await context.taskStore.updateStatus(id: taskID, status: .running)
            await context.taskStore.clearResult(id: taskID)

            var sent = false
            for agentID in task.assigneeIDs {
                if let role = await context.agentRoleForID(agentID), role == .brown {
                    await context.channel.post(ChannelMessage(
                        sender: .agent(context.agentRole),
                        recipientID: agentID,
                        recipient: .agent(.brown),
                        content: "Changes requested on task '\(task.title)': \(feedback)"
                    ))
                    sent = true
                    break
                }
            }

            if !sent {
                return "Task returned to running, but no active Brown agent found to notify. You may need to spawn a new Brown."
            }

            return "Changes requested. Feedback sent to Brown."
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
