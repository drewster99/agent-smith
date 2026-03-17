import Foundation

/// Thread-safe storage for all tasks in the system.
public actor TaskStore {
    private var tasks: [UUID: AgentTask] = [:]
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    /// Registers a callback fired whenever tasks change.
    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    /// All tasks, ordered by creation date.
    public func allTasks() -> [AgentTask] {
        tasks.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Retrieves a single task by ID.
    public func task(id: UUID) -> AgentTask? {
        tasks[id]
    }

    /// Adds a new task and returns it.
    @discardableResult
    public func addTask(title: String, description: String) -> AgentTask {
        let task = AgentTask(title: title, description: description)
        tasks[task.id] = task
        onChange?()
        return task
    }

    /// Updates a task's status.
    public func updateStatus(id: UUID, status: AgentTask.Status) {
        guard var task = tasks[id] else { return }
        task.status = status
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Assigns an agent to a task.
    public func assignAgent(taskID: UUID, agentID: UUID) {
        guard var task = tasks[taskID] else { return }
        if !task.assigneeIDs.contains(agentID) {
            task.assigneeIDs.append(agentID)
            task.updatedAt = Date()
            tasks[taskID] = task
            onChange?()
        }
    }

    /// Restores tasks from a persisted list (e.g., on app launch).
    public func restore(_ persistedTasks: [AgentTask]) {
        for task in persistedTasks {
            tasks[task.id] = task
        }
        onChange?()
    }

    /// Removes all tasks.
    public func clear() {
        tasks.removeAll()
        onChange?()
    }
}
