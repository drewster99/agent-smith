import Foundation

/// A piece of knowledge saved by an agent or the user for future semantic retrieval.
public struct MemoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    /// The textual content of the memory.
    public let content: String
    /// Sentence embedding vector produced by `EmbeddingService`.
    public let embedding: [Float]
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
        embedding: [Float],
        source: Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.embedding = embedding
        self.source = source
        self.tags = tags
        self.sourceTaskID = sourceTaskID
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}
