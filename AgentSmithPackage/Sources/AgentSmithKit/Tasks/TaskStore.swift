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
    /// If the new status is in-progress (pending, running, paused), the task is automatically
    /// restored to the active disposition — it cannot remain archived or deleted while active.
    public func updateStatus(id: UUID, status: AgentTask.Status) {
        guard var task = tasks[id] else { return }
        task.status = status
        task.updatedAt = Date()
        if status.isInProgress {
            task.disposition = .active
        }
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

    // MARK: - Disposition management

    /// Moves a task to the archive bucket.
    /// Returns false without making changes if the task is currently in progress.
    @discardableResult
    public func archive(id: UUID) -> Bool {
        guard let task = tasks[id], !task.status.isInProgress else { return false }
        setDisposition(id: id, disposition: .archived)
        return true
    }

    /// Soft-deletes a task by moving it to Recently Deleted.
    /// Returns false without making changes if the task is currently in progress.
    @discardableResult
    public func softDelete(id: UUID) -> Bool {
        guard let task = tasks[id], !task.status.isInProgress else { return false }
        setDisposition(id: id, disposition: .recentlyDeleted)
        return true
    }

    /// Returns an archived task to the active list.
    public func unarchive(id: UUID) {
        setDisposition(id: id, disposition: .active)
    }

    /// Recovers a recently-deleted task back to the active list.
    public func undelete(id: UUID) {
        setDisposition(id: id, disposition: .active)
    }

    /// Permanently removes a task from the store. Unrecoverable.
    /// Returns false without making changes if the task is currently in progress.
    @discardableResult
    public func permanentlyDelete(id: UUID) -> Bool {
        guard let task = tasks[id], !task.status.isInProgress else { return false }
        tasks.removeValue(forKey: id)
        onChange?()
        return true
    }

    /// Sets a running task to paused.
    public func pause(id: UUID) {
        updateStatus(id: id, status: .paused)
    }

    /// Resets a task back to pending so it can be re-queued.
    public func stop(id: UUID) {
        updateStatus(id: id, status: .pending)
    }

    // MARK: - Bulk operations

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

    // MARK: - Private

    private func setDisposition(id: UUID, disposition: AgentTask.TaskDisposition) {
        guard var task = tasks[id] else { return }
        task.disposition = disposition
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }
}
