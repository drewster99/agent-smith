import Foundation

/// An LLM-generated summary of a completed or failed task, embedded for semantic search.
public struct TaskSummaryEntry: Codable, Identifiable, Sendable {
    /// Matches the `AgentTask.id` this summary was generated from.
    public let id: UUID
    /// The task's title at completion time.
    public let title: String
    /// LLM-generated summary covering problem, outcome, and approach.
    public let summary: String
    /// Composite text used for generating the embedding vector.
    /// Includes title, description, summary, result, commentary, and updates.
    public let embeddingSourceText: String
    /// Single L2-normalized embedding vector for `embeddingSourceText`.
    public let embedding: [Float]
    /// Whether the task completed successfully or failed.
    public let status: AgentTask.Status
    /// When the *task* was originally created (taken from `AgentTask.createdAt`).
    /// This is the date users care about — the moment they asked for the work to be done.
    public let taskCreatedAt: Date
    /// When the *summary* was generated (after the task ran). Distinct from `taskCreatedAt`
    /// because a long-running task can be created days before its summary is written.
    public let createdAt: Date

    public init(
        id: UUID,
        title: String,
        summary: String,
        embeddingSourceText: String,
        embedding: [Float],
        status: AgentTask.Status,
        taskCreatedAt: Date,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.embeddingSourceText = embeddingSourceText
        self.embedding = embedding
        self.status = status
        self.taskCreatedAt = taskCreatedAt
        self.createdAt = createdAt
    }
}
