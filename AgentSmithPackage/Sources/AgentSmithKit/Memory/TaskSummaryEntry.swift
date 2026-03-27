import Foundation

/// An LLM-generated summary of a completed or failed task, embedded for semantic search.
public struct TaskSummaryEntry: Codable, Identifiable, Sendable {
    /// Matches the `AgentTask.id` this summary was generated from.
    public let id: UUID
    /// The task's title at completion time.
    public let title: String
    /// LLM-generated summary covering problem, outcome, and approach.
    public let summary: String
    /// Sentence embedding vector produced by `EmbeddingService`.
    public let embedding: [Float]
    /// Whether the task completed successfully or failed.
    public let status: AgentTask.Status
    /// When the summary was generated.
    public let createdAt: Date

    public init(
        id: UUID,
        title: String,
        summary: String,
        embedding: [Float],
        status: AgentTask.Status,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.embedding = embedding
        self.status = status
        self.createdAt = createdAt
    }
}
