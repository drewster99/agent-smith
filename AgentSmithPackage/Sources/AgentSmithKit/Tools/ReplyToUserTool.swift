import Foundation

/// Brown tool: sends a private message directly to the user.
/// Only available when the user has directly messaged this agent within the last 10 minutes.
public struct ReplyToUserTool: AgentTool {
    public let name = "reply_to_user"
    public let toolDescription = """
        Send a private reply to the user. Only available when the user has messaged you directly \
        within the last 10 minutes.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The message to send to the user.")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    private static let availabilityWindow: TimeInterval = 10 * 60

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        guard context.agentRole == .brown else { return false }
        guard let lastMessage = context.lastDirectUserMessageAt else { return false }
        return Date().timeIntervalSince(lastMessage) <= Self.availabilityWindow
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: OrchestrationRuntime.userID,
            recipient: .user,
            content: message
        ))

        return .success("Reply sent to user.")
    }
}
