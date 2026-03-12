import Foundation

/// Allows any agent to post a message to the shared channel.
public struct SendMessageTool: AgentTool {
    public let name = "send_message"
    public let toolDescription = "Post a message to the shared communication channel visible to all agents and the user."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The message content to post to the channel.")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        let channelMessage = ChannelMessage(
            sender: .agent(context.agentRole),
            content: message
        )
        await context.channel.post(channelMessage)
        return "Message posted to channel."
    }
}
