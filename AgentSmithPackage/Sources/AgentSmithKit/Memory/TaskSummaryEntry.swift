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
    /// Empty when loaded from a legacy multi-vector save and awaiting re-embedding.
    public let embedding: [Float]
    /// Identifier of the embedding model that produced `embedding`. `nil` for legacy
    /// entries that predate model-tagging.
    public let embeddingModelID: String?
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
        embeddingModelID: String?,
        status: AgentTask.Status,
        taskCreatedAt: Date,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.embeddingSourceText = embeddingSourceText
        self.embedding = embedding
        self.embeddingModelID = embeddingModelID
        self.status = status
        self.taskCreatedAt = taskCreatedAt
        self.createdAt = createdAt
    }

    /// Backward-compatible decoding. New format: `embedding: [Float]` plus
    /// `embeddingModelID`. Legacy formats (`[[Double]]` multi-vector or `[Double]`
    /// single-vector) decode as empty `embedding` + nil `embeddingModelID`, which the
    /// startup migration pass picks up and re-embeds with the current model.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        embeddingSourceText = try c.decodeIfPresent(String.self, forKey: .embeddingSourceText)
            ?? (title + "\n" + summary)
        if let v = try? c.decode([Float].self, forKey: .embedding) {
            embedding = v
        } else {
            embedding = []
        }
        embeddingModelID = try c.decodeIfPresent(String.self, forKey: .embeddingModelID)
        status = try c.decode(AgentTask.Status.self, forKey: .status)
        let summaryCreatedAt = try c.decode(Date.self, forKey: .createdAt)
        createdAt = summaryCreatedAt
        taskCreatedAt = try c.decodeIfPresent(Date.self, forKey: .taskCreatedAt) ?? summaryCreatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, embeddingSourceText
        case embedding, embeddingModelID
        case status, createdAt, taskCreatedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(embeddingSourceText, forKey: .embeddingSourceText)
        try c.encode(embedding, forKey: .embedding)
        try c.encodeIfPresent(embeddingModelID, forKey: .embeddingModelID)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(taskCreatedAt, forKey: .taskCreatedAt)
    }
}
