import Foundation

/// A unit of work managed by the orchestration system.
public struct AgentTask: Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var description: String
    public var status: Status
    public var disposition: TaskDisposition
    public var assigneeIDs: [UUID]
    public var result: String?
    public var commentary: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the task first transitions to `.running`.
    public var startedAt: Date?
    /// Set when the task transitions to `.completed` or `.failed`.
    public var completedAt: Date?
    /// Progress updates from Brown, persisted so a restarted Brown has context.
    public var updates: [TaskUpdate]
    /// Compressed summary of Brown's last working state, saved on termination for resumability.
    public var lastBrownContext: String?
    /// LLM-generated summary of the task (populated after completion/failure).
    public var summary: String?
    /// Relevant memories retrieved at task creation, for Brown's context.
    public var relevantMemories: [RelevantMemory]?
    /// Relevant prior task summaries retrieved at task creation.
    public var relevantPriorTasks: [RelevantPriorTask]?

    /// A single progress update recorded on a task.
    public struct TaskUpdate: Codable, Sendable {
        public var date: Date
        public var message: String

        public init(date: Date = Date(), message: String) {
            self.date = date
            self.message = message
        }
    }

    /// Maximum number of updates retained per task.
    public static let maxUpdates = 20

    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case running
        case completed
        case failed
        case paused
        case awaitingReview

        /// Whether this status represents work that is actively running — prevents archiving or deletion.
        public var isInProgress: Bool {
            self == .running || self == .paused || self == .awaitingReview
        }
    }

    public enum TaskDisposition: String, Codable, Sendable {
        /// Visible in the main task list.
        case active
        /// Moved to the archive bucket.
        case archived
        /// Soft-deleted; recoverable from the Recently Deleted bucket.
        case recentlyDeleted
    }

    public init(
        id: UUID = UUID(),
        title: String,
        description: String,
        status: Status = .pending,
        disposition: TaskDisposition = .active,
        assigneeIDs: [UUID] = [],
        result: String? = nil,
        commentary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        updates: [TaskUpdate] = [],
        lastBrownContext: String? = nil,
        summary: String? = nil,
        relevantMemories: [RelevantMemory]? = nil,
        relevantPriorTasks: [RelevantPriorTask]? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.disposition = disposition
        self.assigneeIDs = assigneeIDs
        self.result = result
        self.commentary = commentary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.updates = updates
        self.lastBrownContext = lastBrownContext
        self.summary = summary
        self.relevantMemories = relevantMemories
        self.relevantPriorTasks = relevantPriorTasks
    }

    // MARK: - Codable (backward-compatible with persisted data lacking `disposition`)

    private enum CodingKeys: String, CodingKey {
        case id, title, description, status, disposition, assigneeIDs, result, commentary, createdAt, updatedAt, startedAt, completedAt, updates, lastBrownContext, summary, relevantMemories, relevantPriorTasks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        status = try c.decode(Status.self, forKey: .status)
        disposition = try c.decodeIfPresent(TaskDisposition.self, forKey: .disposition) ?? .active
        assigneeIDs = try c.decode([UUID].self, forKey: .assigneeIDs)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        commentary = try c.decodeIfPresent(String.self, forKey: .commentary)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        updates = try c.decodeIfPresent([TaskUpdate].self, forKey: .updates) ?? []
        lastBrownContext = try c.decodeIfPresent(String.self, forKey: .lastBrownContext)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        relevantMemories = try c.decodeIfPresent([RelevantMemory].self, forKey: .relevantMemories)
        relevantPriorTasks = try c.decodeIfPresent([RelevantPriorTask].self, forKey: .relevantPriorTasks)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(status, forKey: .status)
        try c.encode(disposition, forKey: .disposition)
        try c.encode(assigneeIDs, forKey: .assigneeIDs)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(commentary, forKey: .commentary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        if !updates.isEmpty {
            try c.encode(updates, forKey: .updates)
        }
        try c.encodeIfPresent(lastBrownContext, forKey: .lastBrownContext)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(relevantMemories, forKey: .relevantMemories)
        try c.encodeIfPresent(relevantPriorTasks, forKey: .relevantPriorTasks)
    }
}
