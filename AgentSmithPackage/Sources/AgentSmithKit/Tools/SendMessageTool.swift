import Foundation

/// Allows any agent to post a message to the shared channel, addressed by role name, "user", or UUID.
public struct SendMessageTool: AgentTool {
    public let name = "send_message"
    public let toolDescription = """
        Post a message to the communication channel. \
        Use recipient_id to send privately: pass a role name ("smith", "brown", "jones"), \
        "user" to message the human user, or a UUID for a specific agent instance. \
        Omit recipient_id to post publicly.
        """

    public func description(for role: AgentRole) -> String {
        switch role {
        case .smith:
            return """
                Post a message. \
                Reply to the user with recipient_id: "user". \
                Send instructions to Brown with recipient_id: "brown". \
                Contact Jones with recipient_id: "jones". \
                Omit recipient_id for a public broadcast visible to all agents.
                """
        case .brown:
            return """
                Send a private message to Smith. \
                You may ONLY use recipient_id: "smith" — any other recipient is rejected. \
                Do not attempt to contact the user or other agents directly.
                """
        case .jones:
            return """
                Send a private message to Smith or Brown. \
                You may ONLY use recipient_id: "smith" or recipient_id: "brown". \
                You cannot post publicly or contact the user.
                """
        }
    }

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The message content to post.")
            ]),
            "recipient_id": .dictionary([
                "type": .string("string"),
                "description": .string(
                    "Who to send to: a role name (\"smith\", \"brown\", \"jones\"), " +
                    "\"user\" for the human, or a UUID. Omit for a public message."
                )
            ])
        ]),
        "required": .array([.string("message")])
    ]

    public func parameters(for role: AgentRole) -> [String: AnyCodable] {
        let recipientDescription: String
        switch role {
        case .smith:
            recipientDescription = "Who to send to: \"user\" for the human, \"brown\", \"jones\", or a UUID."
        case .brown:
            recipientDescription = "Must be \"smith\". No other recipients are permitted."
        case .jones:
            recipientDescription = "Must be \"smith\" or \"brown\". No other recipients are permitted."
        }
        let required: AnyCodable = (role == .brown)
            ? .array([.string("message"), .string("recipient_id")])
            : .array([.string("message")])
        return [
            "type": .string("object"),
            "properties": .dictionary([
                "message": .dictionary([
                    "type": .string("string"),
                    "description": .string("The message content to post.")
                ]),
                "recipient_id": .dictionary([
                    "type": .string("string"),
                    "description": .string(recipientDescription)
                ])
            ]),
            "required": required
        ]
    }

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        var recipientID: UUID?
        var recipient: MessageRecipient?

        if case .string(let idString) = arguments["recipient_id"] {
            let resolved = await resolveRecipient(idString, context: context)
            switch resolved {
            case .success(let r):
                recipientID = r.0
                recipient = r.1
            case .failure(let errorMessage):
                return errorMessage
            }
        }

        // Brown may only message Smith directly. Require both sides to be non-nil so a public
        // message (recipientID == nil) is rejected even if Smith isn't running yet (smithID == nil).
        if context.agentRole == .brown {
            let smithID = await context.agentIDForRole(.smith)
            guard let smithID, recipientID == smithID else {
                return "Brown may only send messages to Smith. Use recipient_id: \"smith\"."
            }
        }

        // Jones may only send private messages to Smith or Brown.
        if context.agentRole == .jones {
            guard let r = recipient, case .agent(let role) = r, role == .smith || role == .brown else {
                return "Jones may only send private messages to Smith or Brown."
            }
        }

        let channelMessage = ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: recipientID,
            recipient: recipient,
            content: message
        )
        await context.channel.post(channelMessage)

        if let recipient {
            return "Private message sent to \(recipient.displayName)."
        }
        return "Message posted to channel."
    }

    // MARK: - Private

    private enum RecipientResolution {
        case success((UUID?, MessageRecipient?))
        case failure(String)
    }

    private func resolveRecipient(
        _ idString: String,
        context: ToolContext
    ) async -> RecipientResolution {
        // "user" keyword → fixed user UUID
        if idString.lowercased() == "user" {
            return .success((OrchestrationRuntime.userID, .user))
        }

        // Role name → look up active agent
        if let role = AgentRole(rawValue: idString.lowercased()) {
            guard let agentID = await context.agentIDForRole(role) else {
                return .failure("No active agent with role '\(idString)'.")
            }
            return .success((agentID, .agent(role)))
        }

        // UUID string → existing behavior
        guard let parsed = UUID(uuidString: idString) else {
            return .failure(
                "Invalid recipient_id '\(idString)'. Use a role name (smith, brown, jones), " +
                "\"user\", or a UUID."
            )
        }
        let role = await context.agentRoleForID(parsed)
        return .success((parsed, role.map { .agent($0) }))
    }
}
