import Foundation

/// Smith tool: sends a private message to the human user.
/// Replaces send_message(recipient_id: "user") for Smith's tool set.
public struct MessageUserTool: AgentTool {
    public let name = "message_user"
    public let toolDescription = """
        Send a message to the human user. Use for status updates, questions, and delivering \
        final results. Write as if speaking directly to a person — do not expose internal \
        orchestration details.
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

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        await context.channel.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: OrchestrationRuntime.userID,
            recipient: .user,
            content: message
        ))

        return "Message sent to user."
    }
}
