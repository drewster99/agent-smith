import Foundation

/// Smith tool: schedules a future wake (reminder) so Smith can act on something the user
/// asked to be revisited later. Each wake carries a `reason` (surfaced verbatim when the wake
/// fires) and an optional `task_id` (auto-cancels the wake when that task terminates).
///
/// Multiple wakes can coexist freely — there is no spacing minimum. If the caller wants a
/// single wake to replace another (rather than coexist), they pass `replaces_id`.
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
        Optional: `task_id` (auto-cancels on task completion/failure), `replaces_id` (cancels an \
        existing wake before scheduling the new one — use the id returned by `list_scheduled_wakes`). \
        Multiple wakes can be scheduled at the same time; if you want a single wake to replace \
        another, use `replaces_id`. Call `list_scheduled_wakes` first if you need to check what's \
        already pending.
        """

    /// Minimum allowed delay (or distance from now for `at_time`). Floors short scheduling
    /// errors so the wake doesn't fire on the next loop iteration before context has settled.
    private static let minDelaySeconds: Double = 5
    /// Maximum allowed delay (or distance from now for `at_time`). One year ahead.
    /// The previous one-day cap was too short for legitimate user requests like "remind me
    /// next quarter".
    private static let maxDelaySeconds: Double = 365 * 24 * 60 * 60

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "delay_seconds": .dictionary([
                "type": .string("number"),
                "description": .string("Seconds from now to fire (5–31_536_000, i.e. up to one year). Either delay_seconds OR at_time is required.")
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

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let reason) = arguments["reason"] else {
            throw ToolCallError.missingRequiredArgument("reason")
        }

        let now = Date()
        let wakeAt: Date
        if let value = arguments["at_time"], case .string(let isoString) = value {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let parsed: Date?
            if let p = formatter.date(from: isoString) {
                parsed = p
            } else {
                let lenient = ISO8601DateFormatter()
                lenient.formatOptions = [.withInternetDateTime]
                parsed = lenient.date(from: isoString)
            }
            guard let parsed else {
                return .failure("Invalid at_time: '\(isoString)' is not a valid ISO-8601 timestamp.")
            }
            // Reject `at_time` outside the [now+min, now+max] window. We don't silently
            // clamp here because past or far-future times almost always indicate a model
            // mistake; surfacing the rejection lets the model retry with a sane value.
            let delta = parsed.timeIntervalSince(now)
            if delta < Self.minDelaySeconds {
                return .failure("Invalid at_time: '\(isoString)' is in the past or less than \(Int(Self.minDelaySeconds)) seconds from now. Pick a time at least \(Int(Self.minDelaySeconds)) seconds in the future.")
            }
            if delta > Self.maxDelaySeconds {
                return .failure("Invalid at_time: '\(isoString)' is more than 1 year in the future. The maximum supported lead time is 1 year — pick a closer time.")
            }
            wakeAt = parsed
        } else {
            let rawDelay: Double
            switch arguments["delay_seconds"] {
            case .int(let v):    rawDelay = Double(v)
            case .double(let v): rawDelay = v
            case .string(let s):
                guard let parsed = Double(s) else {
                    return .failure("Invalid delay_seconds: '\(s)' is not a number.")
                }
                rawDelay = parsed
            default:
                return .failure("Either delay_seconds or at_time is required.")
            }
            // Reject (rather than clamp) out-of-range delays so the model retries with a
            // sane value instead of silently waking sooner or later than intended.
            if rawDelay < Self.minDelaySeconds {
                return .failure("Invalid delay_seconds: \(rawDelay) is below the minimum of \(Int(Self.minDelaySeconds)).")
            }
            if rawDelay > Self.maxDelaySeconds {
                return .failure("Invalid delay_seconds: \(rawDelay) exceeds the maximum of \(Int(Self.maxDelaySeconds)) (1 year).")
            }
            wakeAt = now.addingTimeInterval(rawDelay)
        }

        var taskID: UUID?
        if case .string(let tid) = arguments["task_id"] {
            guard let parsed = UUID(uuidString: tid) else {
                return .failure("Invalid task_id: '\(tid)' is not a valid UUID.")
            }
            taskID = parsed
        }
        var replacesID: UUID?
        if case .string(let rid) = arguments["replaces_id"] {
            guard let parsed = UUID(uuidString: rid) else {
                return .failure("Invalid replaces_id: '\(rid)' is not a valid UUID.")
            }
            replacesID = parsed
        }

        let outcome = await context.scheduleWake(wakeAt, reason, taskID, replacesID)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        switch outcome {
        case .scheduled(let wake):
            let taskFragment = wake.taskID.map { " (linked to task \($0.uuidString))" } ?? ""
            return .success("Scheduled wake \(wake.id.uuidString) for \(formatter.string(from: wake.wakeAt))\(taskFragment). Reason: \(wake.reason)")
        case .error(let message):
            return .failure("Could not schedule wake: \(message)")
        }
    }
}
