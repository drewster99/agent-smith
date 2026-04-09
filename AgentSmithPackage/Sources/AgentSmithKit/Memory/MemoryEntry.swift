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
    /// When this memory was originally saved.
    public let createdAt: Date

    /// Set the most recent time an agent-driven search retrieved this memory and used it
    /// (i.e. it appeared in `searchAll` results consumed by a tool or auto-context inject).
    /// `nil` if the memory has never been retrieved by an agent. Browsing in the Memory
    /// editor does NOT update this field.
    public var lastRetrievedAt: Date?

    /// Total number of times an agent-driven search has retrieved this memory. Same scoping
    /// as `lastRetrievedAt` — editor browsing does not increment this.
    public var retrievalCount: Int

    /// Set the most recent time the memory's content or tags were edited. `nil` if the
    /// memory has never been modified since creation.
    public var lastUpdatedAt: Date?

    /// Who performed the most recent edit. `nil` if never edited.
    public var lastUpdatedBy: UpdateSource?

    /// Who originated the memory at save time.
    public enum Source: String, Codable, Sendable {
        case user
        case smith
        case brown
    }

    /// Who performed an edit on an existing memory.
    public enum UpdateSource: String, Codable, Sendable {
        /// Edited by the user via the Memory editor.
        case user
        /// Edited automatically by the system — currently only via `SaveMemoryTool` consolidation.
        case system
    }

    public init(
        id: UUID = UUID(),
        content: String,
        embeddings: [[Double]],
        source: Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil,
        createdAt: Date = Date(),
        lastRetrievedAt: Date? = nil,
        retrievalCount: Int = 0,
        lastUpdatedAt: Date? = nil,
        lastUpdatedBy: UpdateSource? = nil
    ) {
        self.id = id
        self.content = content
        self.embeddings = embeddings
        self.source = source
        self.tags = tags
        self.sourceTaskID = sourceTaskID
        self.createdAt = createdAt
        self.lastRetrievedAt = lastRetrievedAt
        self.retrievalCount = retrievalCount
        self.lastUpdatedAt = lastUpdatedAt
        self.lastUpdatedBy = lastUpdatedBy
    }

    /// Backward-compatible decoding: handles both old `embedding: [Double]` (single vector)
    /// and new `embeddings: [[Double]]` (multi-sentence). Also tolerates pre-existing
    /// records that lack the new retrieval/update tracking fields, and ignores the legacy
    /// `lastAccessedAt` field that has been replaced by `lastRetrievedAt`.
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
        lastRetrievedAt = try c.decodeIfPresent(Date.self, forKey: .lastRetrievedAt)
        retrievalCount = try c.decodeIfPresent(Int.self, forKey: .retrievalCount) ?? 0
        lastUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        lastUpdatedBy = try c.decodeIfPresent(UpdateSource.self, forKey: .lastUpdatedBy)
    }

    private enum CodingKeys: String, CodingKey {
        // Map "embeddings" property to "embedding" JSON key for backward compat.
        case id, content
        case embeddings = "embedding"
        case source, tags, sourceTaskID, createdAt
        case lastRetrievedAt, retrievalCount, lastUpdatedAt, lastUpdatedBy
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
        try c.encodeIfPresent(lastRetrievedAt, forKey: .lastRetrievedAt)
        try c.encode(retrievalCount, forKey: .retrievalCount)
        try c.encodeIfPresent(lastUpdatedAt, forKey: .lastUpdatedAt)
        try c.encodeIfPresent(lastUpdatedBy, forKey: .lastUpdatedBy)
    }
}
