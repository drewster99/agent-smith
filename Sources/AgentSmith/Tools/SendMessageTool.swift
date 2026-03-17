import Foundation

/// Allows any agent to post a message to the shared channel, optionally as a private message to a specific recipient.
public struct SendMessageTool: AgentTool {
    public let name = "send_message"
    public let toolDescription = "Post a message to the communication channel. If recipient_id is provided, the message is delivered only to that agent (private). Otherwise it is public."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The message content to post.")
            ]),
            "recipient_id": .dictionary([
                "type": .string("string"),
                "description": .string("Optional UUID of a specific agent to send a private message to. Omit for a public message.")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        var recipientID: UUID?
        if case .string(let idString) = arguments["recipient_id"] {
            guard let parsed = UUID(uuidString: idString) else {
                return "Invalid recipient_id format: \(idString)"
            }
            recipientID = parsed
        }

        let channelMessage = ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: recipientID,
            content: message
        )
        await context.channel.post(channelMessage)

        if recipientID != nil {
            return "Private message sent."
        }
        return "Message posted to channel."
    }
}
