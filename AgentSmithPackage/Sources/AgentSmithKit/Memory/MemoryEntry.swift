import Foundation

/// A piece of knowledge saved by an agent or the user for future semantic retrieval.
public struct MemoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    /// The textual content of the memory.
    public let content: String
    /// Single L2-normalized embedding vector for the memory's content.
    public let embedding: [Float]
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
        embedding: [Float],
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
        self.embedding = embedding
        self.source = source
        self.tags = tags
        self.sourceTaskID = sourceTaskID
        self.createdAt = createdAt
        self.lastRetrievedAt = lastRetrievedAt
        self.retrievalCount = retrievalCount
        self.lastUpdatedAt = lastUpdatedAt
        self.lastUpdatedBy = lastUpdatedBy
    }
}
