import Foundation

/// Smith tool: sends a private message to Agent Brown.
/// Replaces send_message(recipient_id: "brown") for Smith's tool set.
public struct MessageBrownTool: AgentTool {
    public let name = "message_brown"
    public let toolDescription = """
        Send a message to Agent Brown. Use for task instructions, corrections, and follow-ups. \
        Be specific and unambiguous — Brown is literal and may misinterpret vague instructions.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The message to send to Brown.")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        guard let brownID = await context.agentIDForRole(.brown) else {
            return "No active Brown agent found. Spawn one first with `spawn_brown`."
        }

        await context.channel.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: brownID,
            recipient: .agent(.brown),
            content: message
        ))

        return "Message sent to Brown."
    }
}
