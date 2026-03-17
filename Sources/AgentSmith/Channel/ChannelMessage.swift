import Foundation

/// A message posted to the shared communication channel.
public struct ChannelMessage: Identifiable, Codable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var sender: Sender
    /// The intended recipient. `nil` means the message is public (visible to all agents).
    public var recipientID: UUID?
    public var content: String
    /// File attachments (images, documents, any media).
    public var attachments: [Attachment]
    /// Optional structured metadata (e.g., tool call details).
    public var metadata: [String: AnyCodable]?

    /// Whether this message targets a specific agent rather than the public channel.
    public var isPrivate: Bool { recipientID != nil }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, sender, recipientID, content, attachments, metadata
    }

    /// Backward-compatible decoding: old JSON without newer fields defaults gracefully.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sender = try container.decode(Sender.self, forKey: .sender)
        recipientID = try container.decodeIfPresent(UUID.self, forKey: .recipientID)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
    }

    public enum Sender: Codable, Sendable, Hashable {
        case agent(AgentRole)
        case user
        case system

        /// Display name for the sender.
        public var displayName: String {
            switch self {
            case .agent(let role): return role.displayName
            case .user: return "User"
            case .system: return "System"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sender: Sender,
        recipientID: UUID? = nil,
        content: String,
        attachments: [Attachment] = [],
        metadata: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.recipientID = recipientID
        self.content = content
        self.attachments = attachments
        self.metadata = metadata
    }
}
