import Foundation

/// Brown tool: submits the task result for Smith's review, transitioning it to awaitingReview.
public struct TaskCompleteTool: AgentTool {
    public let name = "task_complete"
    public let toolDescription = """
        Submit your completed work for review. Provide the full result — do not summarize. \
        After calling this, stop working and wait for Smith's verdict. \
        Optionally attach files via `attachment_ids` (existing IDs) or `attachment_paths` \
        (local file paths to ingest) so Smith can review screenshots, generated artifacts, \
        or any output produced during the task.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "result": .dictionary([
                "type": .string("string"),
                "description": .string("The full result of your work. Include everything relevant — do not summarize.")
            ]),
            "commentary": .dictionary([
                "type": .string("string"),
                "description": .string("Optional commentary about approach, caveats, or notes for Smith.")
            ]),
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional UUID strings of existing attachments (from the task description, prior updates, or earlier Brown sessions) to include with the result.")
            ]),
            "attachment_paths": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional local file paths to read and attach to the result. Each is loaded, persisted to the per-session attachments directory, and surfaced to Smith with the awaitingReview banner.")
            ])
        ]),
        "required": .array([.string("result")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let result) = arguments["result"] else {
            // Auto-reject submissions missing the `result` argument entirely.
            // Smith is never involved — the runtime refuses to admit the submission.
            await postAutoRejection(reason: "the `result` argument was missing entirely", context: context)
            throw ToolCallError.missingRequiredArgument("result")
        }

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else {
            // Auto-reject empty/whitespace-only submissions. The task is NEVER transitioned to
            // awaitingReview, so Smith never gets the chance to review (or accept) a result-less
            // task. Brown's LLM sees the failure in its tool result and must retry with real content.
            await postAutoRejection(reason: "the `result` argument was empty or whitespace-only", context: context)
            return .failure("Auto-rejected: result must contain a meaningful summary of the completed work. The task has NOT been submitted for review. Re-read the task requirements and call `task_complete` again with the FULL result.")
        }

        let commentary: String?
        if case .string(let c) = arguments["commentary"] {
            commentary = c
        } else {
            commentary = nil
        }

        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("No active task assigned to you.")
        }

        // Idempotency guard — a duplicate submission isn't really a failure, but it's
        // not a fresh successful submission either. Return success with a clear message.
        if task.status == .awaitingReview || task.status == .completed {
            return .success("Task already submitted for review.")
        }

        let resolution = await TaskUpdateTool.resolveAttachments(arguments: arguments, context: context)
        if let failureMessage = resolution.failure {
            return .failure(failureMessage)
        }
        let attachments = resolution.attachments

        // Store result on the task (survives restarts) and transition status
        await context.taskStore.setResult(id: task.id, result: result, commentary: commentary, attachments: attachments)
        await context.taskStore.updateStatus(id: task.id, status: .awaitingReview)

        // Notify Smith privately
        guard let smithID = await context.agentIDForRole(.smith) else {
            return .success("Task submitted for review: \(task.title)")
        }

        var message = "Task '\(task.title)' is ready for review.\n\nResult:\n\(result)"
        if let commentary {
            message += "\n\nCommentary:\n\(commentary)"
        }

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: message,
            attachments: attachments,
            metadata: [
                "messageKind": .string("task_complete"),
                "taskTitle": .string(task.title)
            ]
        ))

        if attachments.isEmpty {
            return .success("Task submitted for review: \(task.title)")
        }
        let names = attachments.map { $0.filename }.joined(separator: ", ")
        return .success("Task submitted for review: \(task.title) — with \(attachments.count) attachment(s): \(names)")
    }

    /// Posts a system channel message recording an auto-rejection of an empty/missing-result
    /// submission. Makes the rejection visible in the UI and channel log, even though no state
    /// transition occurred. Smith is not involved — this is a runtime-level guard at submission time.
    private func postAutoRejection(reason: String, context: ToolContext) async {
        await context.post(ChannelMessage(
            sender: .system,
            content: "Auto-rejected `task_complete` submission: \(reason). Brown has been told to retry; task remains in its prior state.",
            metadata: [
                "messageKind": .string("submission_auto_rejected"),
                "reason": .string(reason)
            ]
        ))
    }
}
