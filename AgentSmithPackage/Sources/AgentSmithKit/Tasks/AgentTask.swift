import Foundation

/// A unit of work managed by the orchestration system.
public struct AgentTask: Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var description: String
    public var status: Status
    public var disposition: TaskDisposition
    public var assigneeIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case running
        case completed
        case failed
        case paused

        /// Whether this status represents work that is active or waiting — prevents archiving or deletion.
        public var isInProgress: Bool {
            self == .pending || self == .running || self == .paused
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
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.disposition = disposition
        self.assigneeIDs = assigneeIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Codable (backward-compatible with persisted data lacking `disposition`)

    private enum CodingKeys: String, CodingKey {
        case id, title, description, status, disposition, assigneeIDs, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        status = try c.decode(Status.self, forKey: .status)
        disposition = try c.decodeIfPresent(TaskDisposition.self, forKey: .disposition) ?? .active
        assigneeIDs = try c.decode([UUID].self, forKey: .assigneeIDs)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(status, forKey: .status)
        try c.encode(disposition, forKey: .disposition)
        try c.encode(assigneeIDs, forKey: .assigneeIDs)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}
