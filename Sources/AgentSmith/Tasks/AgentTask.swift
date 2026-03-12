import Foundation

/// A unit of work managed by the orchestration system.
public struct AgentTask: Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var description: String
    public var status: Status
    public var assigneeIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case running
        case completed
        case failed
    }

    public init(
        id: UUID = UUID(),
        title: String,
        description: String,
        status: Status = .pending,
        assigneeIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.assigneeIDs = assigneeIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
