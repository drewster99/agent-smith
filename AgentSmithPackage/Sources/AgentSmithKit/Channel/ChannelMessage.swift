import Foundation

/// Who a private channel message is addressed to.
public enum MessageRecipient: Sendable {
    case agent(AgentRole)
    case user

    /// Display name shown in the channel log (e.g. "Smith", or the user's nickname).
    public var displayName: String {
        switch self {
        case .agent(let role): return role.displayName
        case .user:
            let nickname = AgentRole.userNickname
            return nickname.isEmpty ? "User" : nickname
        }
    }
}

extension MessageRecipient: Codable {
    private enum CodingKeys: String, CodingKey { case type, role }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "user":
            self = .user
        case "agent":
            let role = try container.decode(AgentRole.self, forKey: .role)
            self = .agent(role)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unknown MessageRecipient type: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .type)
        case .agent(let role):
            try container.encode("agent", forKey: .type)
            try container.encode(role, forKey: .role)
        }
    }
}

/// A message posted to the shared communication channel.
public struct ChannelMessage: Identifiable, Codable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var sender: Sender
    /// The intended recipient. `nil` means the message is public (visible to all agents).
    public var recipientID: UUID?
    /// Who this private message is addressed to, for display purposes.
    public var recipient: MessageRecipient?
    public var content: String
    /// File attachments (images, documents, any media).
    public var attachments: [Attachment]
    /// Optional structured metadata (e.g., tool call details).
    public var metadata: [String: AnyCodable]?

    /// Whether this message targets a specific agent rather than the public channel.
    public var isPrivate: Bool { recipientID != nil }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, sender, recipientID, recipient, recipientRole, content, attachments, metadata
    }

    /// Backward-compatible decoding: reads the new `recipient` key, falling back to the
    /// legacy `recipientRole` key found in persisted messages written by older builds.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sender = try container.decode(Sender.self, forKey: .sender)
        recipientID = try container.decodeIfPresent(UUID.self, forKey: .recipientID)
        if let r = try container.decodeIfPresent(MessageRecipient.self, forKey: .recipient) {
            recipient = r
        } else if let role = try container.decodeIfPresent(AgentRole.self, forKey: .recipientRole) {
            recipient = .agent(role)
        } else {
            recipient = nil
        }
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(sender, forKey: .sender)
        try container.encodeIfPresent(recipientID, forKey: .recipientID)
        try container.encodeIfPresent(recipient, forKey: .recipient)
        try container.encode(content, forKey: .content)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }

    public enum Sender: Codable, Sendable, Hashable {
        case agent(AgentRole)
        case user
        case system

        /// Display name for the sender.
        public var displayName: String {
            switch self {
            case .agent(let role): return role.displayName
            case .user:
                let nickname = AgentRole.userNickname
                return nickname.isEmpty ? "User" : nickname
            case .system: return "System"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sender: Sender,
        recipientID: UUID? = nil,
        recipient: MessageRecipient? = nil,
        content: String,
        attachments: [Attachment] = [],
        metadata: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.recipientID = recipientID
        self.recipient = recipient
        self.content = content
        self.attachments = attachments
        self.metadata = metadata
    }
}
