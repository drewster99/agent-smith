import Foundation

/// Thread-safe storage for all tasks in the system.
public actor TaskStore {
    private var tasks: [UUID: AgentTask] = [:]
    private var onChange: (@Sendable () -> Void)?
    /// Fired the first time a task transitions to a terminal status (`.completed` or `.failed`).
    /// Used by `OrchestrationRuntime` to cancel any scheduled wakes pinned to the task.
    private var onTaskTerminated: (@Sendable (UUID) -> Void)?

    public init() {}

    /// Registers a callback fired whenever tasks change.
    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    /// Registers a callback fired when a task transitions to a terminal status for the first time.
    public func setOnTaskTerminated(_ handler: @escaping @Sendable (UUID) -> Void) {
        onTaskTerminated = handler
    }

    /// All tasks, newest first.
    public func allTasks() -> [AgentTask] {
        tasks.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Retrieves a single task by ID.
    public func task(id: UUID) -> AgentTask? {
        tasks[id]
    }

    /// Adds a new task and returns it. Also archives any completed tasks older than 4 hours.
    /// When `scheduledRunAt` is non-nil and in the future the new task is created with status
    /// `.scheduled` so the auto-runner skips it; the runtime should pair the call with a
    /// matching wake bound to the new task's id.
    @discardableResult
    public func addTask(
        title: String,
        description: String,
        scheduledRunAt: Date? = nil
    ) -> AgentTask {
        archiveStaleCompleted()
        let initialStatus: AgentTask.Status = (scheduledRunAt.map { $0 > Date() } ?? false) ? .scheduled : .pending
        let task = AgentTask(
            title: title,
            description: description,
            status: initialStatus,
            scheduledRunAt: scheduledRunAt
        )
        tasks[task.id] = task
        onChange?()
        return task
    }

    /// Promotes a `.scheduled` task to `.pending` so the queue (or `run_task`) can pick it up.
    /// No-op when the task is missing, already non-`.scheduled`, or has a future scheduledRunAt
    /// the caller didn't ask to bypass.
    @discardableResult
    public func promoteScheduledToPending(id: UUID) -> Bool {
        guard var task = tasks[id], task.status == .scheduled else { return false }
        task.status = .pending
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
    }

    /// Archives all active completed tasks whose `updatedAt` is older than `interval` seconds.
    /// Called automatically on task creation and on app startup.
    public func archiveStaleCompleted(olderThan interval: TimeInterval = 4 * 3600) {
        let cutoff = Date().addingTimeInterval(-interval)
        var changed = false
        for (id, task) in tasks where task.status == .completed && task.disposition == .active && task.updatedAt < cutoff {
            var updated = task
            updated.disposition = .archived
            tasks[id] = updated
            changed = true
        }
        if changed { onChange?() }
    }

    /// Updates a task's status.
    /// If the new status is in-progress (pending, running, paused), the task is automatically
    /// restored to the active disposition — it cannot remain archived or deleted while active.
    /// The first transition to a terminal status (`.completed`/`.failed`) fires `onTaskTerminated`
    /// so the runtime can dispose any wakes scoped to the task.
    public func updateStatus(id: UUID, status: AgentTask.Status) {
        guard var task = tasks[id] else { return }
        let now = Date()
        let wasTerminal = task.status == .completed || task.status == .failed
        let isTerminal = status == .completed || status == .failed
        task.status = status
        task.updatedAt = now
        if status == .running && task.startedAt == nil {
            task.startedAt = now
        }
        if isTerminal {
            task.completedAt = now
        }
        if status.isInProgress {
            task.disposition = .active
        }
        tasks[id] = task
        onChange?()
        if isTerminal && !wasTerminal {
            onTaskTerminated?(id)
        }
    }

    /// Resets a failed task's terminal state so it can be retried via `run_task`. Clears
    /// `result`, `commentary`, and `completedAt`; the caller is responsible for transitioning
    /// the status back to `.pending` (or via run_task → restart). Returns false if the task
    /// is missing or not in `.failed` state.
    @discardableResult
    public func resetFailedTask(id: UUID) -> Bool {
        guard var task = tasks[id], task.status == .failed else { return false }
        task.result = nil
        task.commentary = nil
        task.completedAt = nil
        task.status = .pending
        task.disposition = .active
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
    }

    /// Reopens a completed task so it can be re-run via `run_task` without creating a
    /// duplicate. Clears `result`, `commentary`, and `completedAt`; flips status back to
    /// `.pending`. Returns false if the task is missing or not in `.completed` state.
    /// Distinct from `resetFailedTask` only by which terminal status it accepts —
    /// callers ask the question they want answered ("reopen completed" vs. "retry failed")
    /// rather than passing a status enum.
    @discardableResult
    public func reopenCompletedTask(id: UUID) -> Bool {
        guard var task = tasks[id], task.status == .completed else { return false }
        task.result = nil
        task.commentary = nil
        task.completedAt = nil
        task.status = .pending
        task.disposition = .active
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
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

    /// Removes an agent from a single task's assignee list.
    /// No-op if the task doesn't exist or the agent wasn't assigned.
    public func unassignAgent(taskID: UUID, agentID: UUID) {
        guard var task = tasks[taskID] else { return }
        guard let idx = task.assigneeIDs.firstIndex(of: agentID) else { return }
        task.assigneeIDs.remove(at: idx)
        task.updatedAt = Date()
        tasks[taskID] = task
        onChange?()
    }

    /// Removes an agent from every task's assignee list. Called when an agent is
    /// terminated so stale UUIDs don't accumulate across respawns.
    /// Returns the IDs of the tasks that were actually modified (for callers that
    /// want to log or persist just those).
    @discardableResult
    public func unassignAgentFromAllTasks(agentID: UUID) -> [UUID] {
        var modified: [UUID] = []
        let now = Date()
        for (taskID, task) in tasks {
            guard let idx = task.assigneeIDs.firstIndex(of: agentID) else { continue }
            var updated = task
            updated.assigneeIDs.remove(at: idx)
            updated.updatedAt = now
            tasks[taskID] = updated
            modified.append(taskID)
        }
        if !modified.isEmpty {
            onChange?()
        }
        return modified
    }

    /// Returns the currently active running or awaiting-review task, if any.
    ///
    /// Used by Smith (who orchestrates tasks but is never in a task's `assigneeIDs`)
    /// to determine which task it's currently working in service of. When multiple
    /// tasks are active simultaneously (rare), returns the most recently started —
    /// consistent with the startup migration's `windows.last(where:)` preference.
    public func currentActiveTask() -> AgentTask? {
        tasks.values
            .filter { $0.disposition == .active && ($0.status == .running || $0.status == .awaitingReview) }
            .max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) })
    }

    /// Returns the oldest actionable task assigned to the given agent.
    ///
    /// Tasks are sorted by `createdAt` ascending so the result is deterministic
    /// regardless of dictionary iteration order.
    public func taskForAgent(agentID: UUID) -> AgentTask? {
        let actionableStatuses: Set<AgentTask.Status> = [.pending, .running, .paused, .awaitingReview, .interrupted]
        return tasks.values
            .filter { $0.assigneeIDs.contains(agentID) && actionableStatuses.contains($0.status) }
            .sorted { $0.createdAt < $1.createdAt }
            .first
    }

    /// Appends a progress update to a task, enforcing the per-task cap.
    public func addUpdate(id: UUID, message: String) {
        guard var task = tasks[id] else { return }
        task.updates.append(AgentTask.TaskUpdate(message: message))
        if task.updates.count > AgentTask.maxUpdates {
            task.updates.removeFirst(task.updates.count - AgentTask.maxUpdates)
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Replaces a task's description entirely.
    /// Only allowed for runnable tasks (pending, paused, or interrupted).
    /// Returns true if the update succeeded, false if the task wasn't found or status doesn't allow editing.
    @discardableResult
    public func updateDescription(id: UUID, description: String) -> Bool {
        guard var task = tasks[id] else { return false }
        guard task.status.isRunnable else { return false }
        task.description = description
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
    }

    /// Appends a clearly-labeled amendment to a task's description.
    /// Used by Smith to relay user clarifications so that Brown and Jones see the updated context.
    public func amendDescription(id: UUID, amendment: String) {
        guard var task = tasks[id] else { return }
        task.description += "\n\n[Amendment]: \(amendment)"
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Stores a result (and optional commentary) on a task.
    public func setResult(id: UUID, result: String, commentary: String?) {
        guard var task = tasks[id] else { return }
        task.result = result
        task.commentary = commentary
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Saves a compressed summary of Brown's last working state for resumability.
    public func setLastBrownContext(id: UUID, context: String) {
        guard var task = tasks[id] else { return }
        task.lastBrownContext = context
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Increments the task's acknowledgment counter and returns the new value. Called
    /// by `TaskAcknowledgedTool` on every ack so a respawned Brown can distinguish
    /// a first-time ack (count == 1) from a continuation (count > 1) without relying
    /// on the fragile `updates.isEmpty` heuristic.
    @discardableResult
    public func incrementAcknowledgmentCount(id: UUID) -> Int {
        guard var task = tasks[id] else { return 0 }
        task.acknowledgmentCount += 1
        task.updatedAt = Date()
        let newCount = task.acknowledgmentCount
        tasks[id] = task
        onChange?()
        return newCount
    }

    /// Stores an LLM-generated summary on a completed or failed task.
    public func setSummary(id: UUID, summary: String) {
        guard var task = tasks[id] else { return }
        task.summary = summary
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Stores relevant memories and prior tasks on a task (set at creation time).
    public func setRelevantContext(
        id: UUID,
        memories: [RelevantMemory]?,
        priorTasks: [RelevantPriorTask]?
    ) {
        guard var task = tasks[id] else { return }
        task.relevantMemories = memories
        task.relevantPriorTasks = priorTasks
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Clears the stored result and commentary on a task.
    public func clearResult(id: UUID) {
        guard var task = tasks[id] else { return }
        task.result = nil
        task.commentary = nil
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
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

    /// Marks a running task as interrupted so it can be resumed later.
    public func stop(id: UUID) {
        updateStatus(id: id, status: .interrupted)
    }

    // MARK: - Bulk operations

    /// Restores tasks from a persisted list (e.g., on app launch).
    ///
    /// Clears every restored task's `assigneeIDs` — persisted agent UUIDs are
    /// all stale at this point (the agents they refer to died with the previous
    /// process). The runtime will re-populate the list as it spawns fresh agents
    /// and assigns them via `assignAgent`.
    public func restore(_ persistedTasks: [AgentTask]) {
        for var task in persistedTasks {
            task.assigneeIDs.removeAll()
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
