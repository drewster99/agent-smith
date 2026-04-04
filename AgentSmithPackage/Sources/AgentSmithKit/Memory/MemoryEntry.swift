import Foundation

/// A piece of knowledge saved by an agent or the user for future semantic retrieval.
public struct MemoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    /// The textual content of the memory.
    public let content: String
    /// Per-sentence embedding vectors produced by `EmbeddingService.splitAndEmbed`.
    public let embeddings: [[Double]]
    /// Who created this memory.
    public let source: Source
    /// Optional categorization tags.
    public let tags: [String]
    /// The task that was active when this memory was saved, if any.
    public let sourceTaskID: UUID?
    public let createdAt: Date
    /// Updated each time this memory appears in a search result.
    public var lastAccessedAt: Date

    /// Who originated the memory.
    public enum Source: String, Codable, Sendable {
        case user
        case smith
        case brown
    }

    public init(
        id: UUID = UUID(),
        content: String,
        embeddings: [[Double]],
        source: Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.embeddings = embeddings
        self.source = source
        self.tags = tags
        self.sourceTaskID = sourceTaskID
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }

    /// Backward-compatible decoding: handles both old `embedding: [Double]`
    /// (single vector) and new `embeddings: [[Double]]` (multi-sentence).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        if let multi = try? c.decode([[Double]].self, forKey: .embeddings) {
            embeddings = multi
        } else {
            // Legacy: single vector stored as "embedding" (Float or Double)
            let single = try c.decode([Double].self, forKey: .embeddings)
            embeddings = [single]
        }
        source = try c.decode(Source.self, forKey: .source)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        sourceTaskID = try c.decodeIfPresent(UUID.self, forKey: .sourceTaskID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastAccessedAt = try c.decode(Date.self, forKey: .lastAccessedAt)
    }

    private enum CodingKeys: String, CodingKey {
        // Map "embeddings" to also decode legacy "embedding" key
        case id, content, embeddings = "embedding", source, tags, sourceTaskID, createdAt, lastAccessedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(content, forKey: .content)
        try c.encode(embeddings, forKey: .embeddings)
        try c.encode(source, forKey: .source)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(sourceTaskID, forKey: .sourceTaskID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastAccessedAt, forKey: .lastAccessedAt)
    }
}
