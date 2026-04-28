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
    /// Number of times `task_acknowledged` has been called for this task. Starts at 0;
    /// incremented each time Brown acknowledges. A value > 1 means Brown is picking up
    /// after a prior run (rejection-revision or respawn), not a fresh assignment.
    /// Persisted so the signal survives app restart and new-Brown spawns.
    public var acknowledgmentCount: Int
    /// Compressed summary of Brown's last working state, saved on termination for resumability.
    public var lastBrownContext: String?
    /// LLM-generated summary of the task (populated after completion/failure).
    public var summary: String?
    /// Relevant memories retrieved at task creation, for Brown's context.
    public var relevantMemories: [RelevantMemory]?
    /// Relevant prior task summaries retrieved at task creation.
    public var relevantPriorTasks: [RelevantPriorTask]?
    /// When set, the task is held in `.scheduled` status (or `.pending` after the time
    /// arrives) and will not be auto-run by the queue until this date passes. The runtime
    /// schedules a matching wake bound to `id` so Smith is notified at fire time.
    public var scheduledRunAt: Date?
    /// Timestamp of the most recent user edit to `description` (or other user-mutable
    /// fields, when added). `nil` for tasks that have never been edited. The UI surfaces
    /// this as an "edited" indicator. Editing does not change `status` — a completed
    /// task remains `.completed` after a description edit.
    public var lastEditedAt: Date?

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
        /// The task was running when the app was interrupted (crash or force-quit).
        case interrupted
        /// The task is queued with a future `scheduledRunAt`. The auto-runner skips these,
        /// and `run_task` refuses to start them until the runtime promotes the task to
        /// `.pending` at fire time.
        case scheduled

        /// Whether this status represents work that is actively running — prevents archiving or deletion.
        public var isInProgress: Bool {
            self == .running || self == .paused || self == .awaitingReview
        }

        /// Whether this status allows `run_task` to start execution. `.scheduled` is
        /// deliberately excluded — calling `run_task` on a scheduled task before its fire
        /// time should be an explicit override, not a silent advance.
        public var isRunnable: Bool {
            self == .pending || self == .paused || self == .interrupted
        }

        /// Whether the user can edit the task's description in this state. Includes the
        /// runnable states plus terminal states (`completed`, `failed`) and `scheduled`.
        /// Excludes `running` and `awaitingReview` — those are actively in-flight and
        /// editing the description while Brown or Smith is reading it would be confusing.
        /// Description edits never change the status; the "edited" affordance is surfaced
        /// via `AgentTask.lastEditedAt` instead.
        public var isDescriptionEditable: Bool {
            switch self {
            case .pending, .paused, .interrupted, .scheduled, .completed, .failed:
                return true
            case .running, .awaitingReview:
                return false
            }
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
        acknowledgmentCount: Int = 0,
        lastBrownContext: String? = nil,
        summary: String? = nil,
        relevantMemories: [RelevantMemory]? = nil,
        relevantPriorTasks: [RelevantPriorTask]? = nil,
        scheduledRunAt: Date? = nil,
        lastEditedAt: Date? = nil
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
        self.acknowledgmentCount = acknowledgmentCount
        self.lastBrownContext = lastBrownContext
        self.summary = summary
        self.relevantMemories = relevantMemories
        self.relevantPriorTasks = relevantPriorTasks
        self.scheduledRunAt = scheduledRunAt
        self.lastEditedAt = lastEditedAt
    }

    // MARK: - Codable (backward-compatible with persisted data lacking `disposition`)

    private enum CodingKeys: String, CodingKey {
        case id, title, description, status, disposition, assigneeIDs, result, commentary, createdAt, updatedAt, startedAt, completedAt, updates, acknowledgmentCount, lastBrownContext, summary, relevantMemories, relevantPriorTasks, scheduledRunAt, lastEditedAt
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
        acknowledgmentCount = try c.decodeIfPresent(Int.self, forKey: .acknowledgmentCount) ?? 0
        lastBrownContext = try c.decodeIfPresent(String.self, forKey: .lastBrownContext)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        relevantMemories = try c.decodeIfPresent([RelevantMemory].self, forKey: .relevantMemories)
        relevantPriorTasks = try c.decodeIfPresent([RelevantPriorTask].self, forKey: .relevantPriorTasks)
        scheduledRunAt = try c.decodeIfPresent(Date.self, forKey: .scheduledRunAt)
        lastEditedAt = try c.decodeIfPresent(Date.self, forKey: .lastEditedAt)
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
        if acknowledgmentCount > 0 {
            try c.encode(acknowledgmentCount, forKey: .acknowledgmentCount)
        }
        try c.encodeIfPresent(lastBrownContext, forKey: .lastBrownContext)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(relevantMemories, forKey: .relevantMemories)
        try c.encodeIfPresent(relevantPriorTasks, forKey: .relevantPriorTasks)
        try c.encodeIfPresent(scheduledRunAt, forKey: .scheduledRunAt)
        try c.encodeIfPresent(lastEditedAt, forKey: .lastEditedAt)
    }
}
