import Foundation

/// Allows an agent to schedule a deferred wake-up so it re-checks the channel
/// even if no new messages arrive. Useful for retrying after rate limits,
/// polling for long-running operations, etc.
public struct ScheduleFollowUpTool: AgentTool {
    public let name = "schedule_followup"
    public let toolDescription = """
        Schedule a follow-up check after a delay (5 seconds – 24 hours). \
        The agent will wake and review the channel even if no new messages arrive. \
        New messages will still cause an earlier wake. \
        Use this when you need to retry after a rate limit, poll for a long-running \
        operation, or check back after waiting for external activity.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "delay_seconds": .dictionary([
                "type": .string("number"),
                "description": .string("Seconds to wait before the follow-up (5–86400).")
            ])
        ]),
        "required": .array([.string("delay_seconds")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        let rawDelay: Double
        switch arguments["delay_seconds"] {
        case .int(let v):    rawDelay = Double(v)
        case .double(let v): rawDelay = v
        default: throw ToolCallError.missingRequiredArgument("delay_seconds")
        }

        let delay = min(max(rawDelay, 5), 86400)
        await context.scheduleFollowUp(delay)

        let description: String
        if delay >= 3600 {
            description = String(format: "%.1f hour(s)", delay / 3600)
        } else if delay >= 60 {
            description = "\(Int(delay / 60)) minute(s)"
        } else {
            description = "\(Int(delay)) second(s)"
        }
        return "Follow-up scheduled in \(description)."
    }
}
