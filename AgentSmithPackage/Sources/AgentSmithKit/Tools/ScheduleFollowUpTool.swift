import Foundation

/// Smith tool: schedules a future wake (reminder) so Smith can act on something the user
/// asked to be revisited later. Each wake carries a `reason` (surfaced verbatim when the wake
/// fires) and an optional `task_id` (auto-cancels the wake when that task terminates).
///
/// Multiple wakes can coexist. Conflict detection: if a wake is already scheduled within
/// 60 seconds of the requested time, the call returns the conflicting wake's id and details
/// instead of scheduling — Smith should resolve by passing `replaces_id` or picking a different
/// time, after asking the user.
///
/// Replaces the old single-slot `schedule_followup` polling tool. The runtime no longer needs
/// Smith to poll Brown — that's handled by an automatic 10-minute Brown-activity digest.
public struct ScheduleFollowUpTool: AgentTool {
    public let name = "schedule_wake"
    public let toolDescription = """
        Schedule a future wake-up so you can act on something the user asked you to revisit later. \
        Use this for user-driven reminders ("ping me at 7pm", "check on the deploy in 2 hours"). \
        DO NOT use this to poll Brown's progress — the runtime sends you an automatic Brown-activity \
        digest every 10 minutes. \
        Required: `delay_seconds` OR `at_time` (ISO-8601), `reason`. \
        Optional: `task_id` (auto-cancels on task completion/failure), `replaces_id` (overwrites \
        a conflicting existing wake — use the id returned by `list_scheduled_wakes`). \
        Before scheduling, call `list_scheduled_wakes` to check for duplicates and ambiguity. \
        On conflict (any existing wake within 60 seconds of the requested time), the call returns \
        the conflicting wake's details and does NOT schedule — ask the user how to resolve.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "delay_seconds": .dictionary([
                "type": .string("number"),
                "description": .string("Seconds from now to fire (5–86400). Either delay_seconds OR at_time is required.")
            ]),
            "at_time": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute ISO-8601 timestamp to fire at. Either delay_seconds OR at_time is required.")
            ]),
            "reason": .dictionary([
                "type": .string("string"),
                "description": .string("Why the wake was scheduled. Surfaced verbatim when the wake fires so you remember why. Required.")
            ]),
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("Optional UUID of a task this wake is associated with. The wake is auto-cancelled when the task transitions to completed/failed.")
            ]),
            "replaces_id": .dictionary([
                "type": .string("string"),
                "description": .string("Optional UUID of an existing wake to overwrite. Use to resolve a conflict reported by a prior schedule_wake call.")
            ])
        ]),
        "required": .array([.string("reason")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let reason) = arguments["reason"] else {
            throw ToolCallError.missingRequiredArgument("reason")
        }

        let wakeAt: Date
        if let value = arguments["at_time"], case .string(let isoString) = value {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: isoString) {
                wakeAt = parsed
            } else {
                let lenient = ISO8601DateFormatter()
                lenient.formatOptions = [.withInternetDateTime]
                guard let parsed = lenient.date(from: isoString) else {
                    return "Invalid at_time: '\(isoString)' is not a valid ISO-8601 timestamp."
                }
                wakeAt = parsed
            }
        } else {
            let rawDelay: Double
            switch arguments["delay_seconds"] {
            case .int(let v):    rawDelay = Double(v)
            case .double(let v): rawDelay = v
            case .string(let s):
                guard let parsed = Double(s) else {
                    return "Invalid delay_seconds: '\(s)' is not a number."
                }
                rawDelay = parsed
            default:
                return "Either delay_seconds or at_time is required."
            }
            let delay = min(max(rawDelay, 5), 86400)
            wakeAt = Date().addingTimeInterval(delay)
        }

        var taskID: UUID?
        if case .string(let tid) = arguments["task_id"] {
            guard let parsed = UUID(uuidString: tid) else {
                return "Invalid task_id: '\(tid)' is not a valid UUID."
            }
            taskID = parsed
        }
        var replacesID: UUID?
        if case .string(let rid) = arguments["replaces_id"] {
            guard let parsed = UUID(uuidString: rid) else {
                return "Invalid replaces_id: '\(rid)' is not a valid UUID."
            }
            replacesID = parsed
        }

        let outcome = await context.scheduleWake(wakeAt, reason, taskID, replacesID)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        switch outcome {
        case .scheduled(let wake):
            let taskFragment = wake.taskID.map { " (linked to task \($0.uuidString))" } ?? ""
            return "Scheduled wake \(wake.id.uuidString) for \(formatter.string(from: wake.wakeAt))\(taskFragment). Reason: \(wake.reason)"
        case .conflict(let existing, let requestedAt):
            let lines = existing.map { wake -> String in
                let taskFragment = wake.taskID.map { " task=\($0.uuidString)" } ?? ""
                return "  • id=\(wake.id.uuidString) at=\(formatter.string(from: wake.wakeAt))\(taskFragment) reason=\"\(wake.reason)\""
            }
            return """
                Conflict: a wake is already scheduled within 60 seconds of \(formatter.string(from: requestedAt)). Existing wake(s):
                \(lines.joined(separator: "\n"))
                To overwrite, call schedule_wake again with `replaces_id` set to the existing wake's id. \
                Otherwise, ask the user whether to keep the existing wake, replace it, or pick a different time.
                """
        case .error(let message):
            return "Could not schedule wake: \(message)"
        }
    }
}
