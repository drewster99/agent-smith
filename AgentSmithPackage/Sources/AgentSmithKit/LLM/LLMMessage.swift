import Foundation

/// Image data for multimodal LLM messages.
public struct LLMImageContent: Sendable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// A single message in an LLM conversation.
public struct LLMMessage: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public enum Content: Codable, Sendable {
        case text(String)
        case toolCalls([LLMToolCall])
        /// Assistant returned both reasoning text and tool calls in one response.
        case mixed(text: String, toolCalls: [LLMToolCall])
        case toolResult(toolCallID: String, content: String)

        private enum CodingKeys: String, CodingKey {
            case type, text, toolCalls, toolCallID, content
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try container.encode("text", forKey: .type)
                try container.encode(value, forKey: .text)
            case .toolCalls(let calls):
                try container.encode("toolCalls", forKey: .type)
                try container.encode(calls, forKey: .toolCalls)
            case .mixed(let value, let calls):
                try container.encode("mixed", forKey: .type)
                try container.encode(value, forKey: .text)
                try container.encode(calls, forKey: .toolCalls)
            case .toolResult(let id, let content):
                try container.encode("toolResult", forKey: .type)
                try container.encode(id, forKey: .toolCallID)
                try container.encode(content, forKey: .content)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                let value = try container.decode(String.self, forKey: .text)
                self = .text(value)
            case "toolCalls":
                let calls = try container.decode([LLMToolCall].self, forKey: .toolCalls)
                self = .toolCalls(calls)
            case "mixed":
                let value = try container.decode(String.self, forKey: .text)
                let calls = try container.decode([LLMToolCall].self, forKey: .toolCalls)
                self = .mixed(text: value, toolCalls: calls)
            case "toolResult":
                let id = try container.decode(String.self, forKey: .toolCallID)
                let content = try container.decode(String.self, forKey: .content)
                self = .toolResult(toolCallID: id, content: content)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown content type: \(type)"
                )
            }
        }

        /// Convenience accessor for the text value, if this is a text content.
        public var textValue: String? {
            switch self {
            case .text(let value): return value
            case .mixed(let value, _): return value
            default: return nil
            }
        }
    }

    public var role: Role
    public var content: Content
    /// Image/media data for multimodal messages. Not included in Codable.
    public var images: [LLMImageContent]?

    private enum CodingKeys: String, CodingKey {
        case role, content
    }

    public init(role: Role, content: Content, images: [LLMImageContent]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }

    /// Convenience initializer for simple text messages.
    public init(role: Role, text: String, images: [LLMImageContent]? = nil) {
        self.role = role
        self.content = .text(text)
        self.images = images
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(Content.self, forKey: .content)
        images = nil
    }

    /// Rough character count for context window estimation (~3 chars per token).
    public var estimatedCharacterCount: Int {
        // Each image is roughly 1000 tokens worth
        let imageChars = (images?.count ?? 0) * 3000
        switch content {
        case .text(let s):
            return s.count + imageChars
        case .toolCalls(let calls):
            return calls.reduce(0) { $0 + $1.name.count + $1.arguments.count + 20 } + imageChars
        case .mixed(let text, let calls):
            return text.count + calls.reduce(0) { $0 + $1.name.count + $1.arguments.count + 20 } + imageChars
        case .toolResult(let toolCallID, let content):
            return toolCallID.count + content.count + 20 + imageChars
        }
    }
}
