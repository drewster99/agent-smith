import Foundation

/// Allows Jones to flag dangerous activity to the user.
public struct AlertUserTool: AgentTool {
    public let name = "alert_user"
    public let toolDescription = "Alert the user about a dangerous or suspicious action detected by the safety monitor."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "severity": .dictionary([
                "type": .string("string"),
                "enum": .array([.string("warning"), .string("critical")]),
                "description": .string("Severity level of the alert.")
            ]),
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("Description of the dangerous action detected.")
            ]),
            "offending_agent_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the agent that performed the dangerous action, if applicable.")
            ])
        ]),
        "required": .array([.string("severity"), .string("message")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let severity) = arguments["severity"] else {
            throw ToolCallError.missingRequiredArgument("severity")
        }
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        let prefix = severity == "critical" ? "🚨 CRITICAL SAFETY ALERT" : "⚠️ Safety Warning"

        var metadata: [String: AnyCodable] = [
            "severity": .string(severity),
            "alert_type": .string("safety")
        ]

        if case .string(let agentID) = arguments["offending_agent_id"] {
            metadata["offending_agent_id"] = .string(agentID)
        }

        await context.channel.post(ChannelMessage(
            sender: .system,
            content: "\(prefix): \(message)",
            metadata: metadata
        ))

        return "Alert posted to channel."
    }
}
