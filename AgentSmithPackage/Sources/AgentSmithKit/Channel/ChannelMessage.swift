import Foundation
import SwiftLLMKit

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

    // MARK: - Context stamping (added in Phase 2)
    // All optional so historical messages decode cleanly. Populated at post time from
    // the sending/receiving agent's current state; also backfilled on older messages
    // by joining to nearby UsageRecords during the startup migration.

    /// Task this message was posted in service of, if any. System messages and
    /// unrelated chatter remain nil.
    public var taskID: UUID?
    /// Session ID of the orchestration run during which this message was posted.
    /// Auto-stamped by `MessageChannel.post` if nil at call time.
    public var sessionID: UUID?
    /// Provider ID of the model context this message is associated with. For agent
    /// messages this is the sending agent's current providerID; for user messages it
    /// is the receiving agent's; for system/tool-result messages it is the
    /// originating agent's. Nil when there's no meaningful attribution.
    public var providerID: String?
    /// Wire model ID associated with this message (mirror of `providerID` semantics).
    public var modelID: String?
    /// Full ModelConfiguration snapshot associated with this message. Like on
    /// `UsageRecord`, embedded directly so context-size/temperature/cache settings
    /// survive even if the source config is later deleted or edited.
    public var configuration: ModelConfiguration?

    /// Whether this message targets a specific agent rather than the public channel.
    public var isPrivate: Bool { recipientID != nil }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, sender, recipientID, recipient, recipientRole, content, attachments, metadata
        case taskID, sessionID, providerID, modelID, configuration
    }

    /// Backward-compatible decoding: reads the new `recipient` key, falling back to the
    /// legacy `recipientRole` key found in persisted messages written by older builds.
    /// Context-stamping fields (taskID, sessionID, providerID, modelID, configuration)
    /// are all optional; old messages decode them as nil.
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
        taskID = try container.decodeIfPresent(UUID.self, forKey: .taskID)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        configuration = try container.decodeIfPresent(ModelConfiguration.self, forKey: .configuration)
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
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encodeIfPresent(configuration, forKey: .configuration)
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
        metadata: [String: AnyCodable]? = nil,
        taskID: UUID? = nil,
        sessionID: UUID? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        configuration: ModelConfiguration? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.recipientID = recipientID
        self.recipient = recipient
        self.content = content
        self.attachments = attachments
        self.metadata = metadata
        self.taskID = taskID
        self.sessionID = sessionID
        self.providerID = providerID
        self.modelID = modelID
        self.configuration = configuration
    }
}
