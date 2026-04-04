import Foundation

/// An LLM-generated summary of a completed or failed task, embedded for semantic search.
public struct TaskSummaryEntry: Codable, Identifiable, Sendable {
    /// Matches the `AgentTask.id` this summary was generated from.
    public let id: UUID
    /// The task's title at completion time.
    public let title: String
    /// LLM-generated summary covering problem, outcome, and approach.
    public let summary: String
    /// Composite text used for generating the embedding vectors.
    /// Includes title, description, summary, result, commentary, and updates.
    public let embeddingSourceText: String
    /// Per-sentence embedding vectors produced by `EmbeddingService.splitAndEmbed`.
    public let embeddings: [[Double]]
    /// Whether the task completed successfully or failed.
    public let status: AgentTask.Status
    /// When the summary was generated.
    public let createdAt: Date

    public init(
        id: UUID,
        title: String,
        summary: String,
        embeddingSourceText: String,
        embeddings: [[Double]],
        status: AgentTask.Status,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.embeddingSourceText = embeddingSourceText
        self.embeddings = embeddings
        self.status = status
        self.createdAt = createdAt
    }

    /// Backward-compatible decoding: handles old `embedding: [Double]` (single vector),
    /// new `embeddings: [[Double]]` (multi-sentence), and missing `embeddingSourceText`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        embeddingSourceText = try c.decodeIfPresent(String.self, forKey: .embeddingSourceText)
            ?? (title + "\n" + summary)
        if let multi = try? c.decode([[Double]].self, forKey: .embeddings) {
            embeddings = multi
        } else {
            let single = try c.decode([Double].self, forKey: .embeddings)
            embeddings = [single]
        }
        status = try c.decode(AgentTask.Status.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, embeddingSourceText
        // Map "embeddings" property to "embedding" JSON key for backward compat
        case embeddings = "embedding"
        case status, createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(embeddingSourceText, forKey: .embeddingSourceText)
        try c.encode(embeddings, forKey: .embeddings)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
    }
}
