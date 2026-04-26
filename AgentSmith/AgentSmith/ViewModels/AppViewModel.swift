import SwiftUI
import AgentSmithKit
import SwiftLLMKit
import UniformTypeIdentifiers
import os

/// Bridges one session's orchestration runtime to the SwiftUI UI.
///
/// Each session (tab/window) owns its own `AppViewModel`, which owns its own
/// `OrchestrationRuntime`, `TaskStore`, channel log, and attachments. Shared app-level
/// state (LLM catalog, speech, billing, memories) lives on `SharedAppState`.
@Observable
@MainActor
final class AppViewModel {
    let session: Session
    let shared: SharedAppState

    var messages: [ChannelMessage] = []
    var tasks: [AgentTask] = []
    /// Active scheduled wakes (timers) for this session. Refreshed via runtime callbacks
    /// and on demand from the View → Timers window.
    var activeTimers: [ScheduledWake] = []
    /// Append-only timer history rows displayed in the Timers history pane. Newest first.
    var timerHistory: [TimerEvent] = []
    /// Whether the user has restored the persisted history into the transcript.
    var hasRestoredHistory = false
    /// Number of messages loaded from disk at launch (available for restore).
    var persistedHistoryCount = 0
    /// The first task currently awaiting Smith's review, if any. Drives the review banner.
    var taskAwaitingReview: AgentTask? {
        tasks.first { $0.status == .awaitingReview }
    }
    /// Set when a task action (archive, delete) is blocked; drives the error alert.
    var taskActionError: String? = nil
    /// Set to true after `loadPersistedState()` finishes for this session.
    var hasLoadedPersistedState = false
    /// Whether Smith automatically runs the next pending task after completing one.
    var autoRunNextTask: Bool = true {
        didSet {
            persistSessionStateAsync()
            Task { await runtime?.setAutoAdvance(autoRunNextTask) }
        }
    }
    /// Whether interrupted tasks are automatically resumed on launch.
    var autoRunInterruptedTasks: Bool = false {
        didSet { persistSessionStateAsync() }
    }
    var isRunning = false
    var isAborted = false
    var abortReason = ""
    var inputText = ""
    var pendingAttachments: [Attachment] = []
    /// History of sent messages for up/down arrow recall (per-tab).
    private var messageHistory: [String] = []
    /// Current position in message history (-1 = not browsing, 0 = most recent).
    private var historyIndex = -1
    /// Stash of the in-progress text before the user started browsing history.
    private var historyStash = ""
    private static let maxMessageHistory = 100
    /// Roles of agents that are currently waiting for an LLM response.
    var processingRoles: Set<AgentRole> = []
    /// Tools available to each agent role, populated when agents come online.
    var agentToolNames: [AgentRole: [String]] = [:]
    /// Whether the Inspector panel is visible.
    var showInspector = false
    /// Dedicated observable store for inspector data, updated via push callbacks.
    let inspectorStore = AgentInspectorStore()

    /// Per-session idle poll intervals for each agent role (seconds).
    var agentPollIntervals: [AgentRole: TimeInterval] = [
        .smith: 20, .brown: 25, .jones: 13
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session maximum tool calls per LLM response for each agent role.
    var agentMaxToolCalls: [AgentRole: Int] = [
        .smith: 100, .brown: 100, .jones: 100
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session message debounce intervals for each agent role (seconds).
    var agentMessageDebounceIntervals: [AgentRole: TimeInterval] = [
        .smith: 1, .brown: 1, .jones: 1
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session: maps each agent role to a `ModelConfiguration.id`.
    var agentAssignments: [AgentRole: UUID] = [:] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session tool allowlist. Missing/true = enabled. Currently no UI; data model only.
    var toolsEnabled: [String: Bool] = [:] {
        didSet { persistSessionStateAsync() }
    }

    private let logger = Logger(subsystem: "com.agentsmith", category: "AppViewModel")
    private var runtime: OrchestrationRuntime?
    /// Kept alive independently of `runtime` so task operations work even when agents aren't running.
    private var taskStore: TaskStore?
    private var channelStreamTask: Task<Void, Never>?
    let persistenceManager: PersistenceManager
    /// Full message history — a superset of `messages`. Never cleared; always written to disk.
    private var allPersistedMessages: [ChannelMessage] = []
    /// Wakes loaded from disk in `loadPersistedState()` and consumed by `start()` to seed
    /// Smith's actor before the run loop begins. Drops to nil after consumption — subsequent
    /// snapshots are taken live from the runtime via `currentScheduledWakes()`.
    private var persistedWakesSnapshot: [ScheduledWake] = []

    init(session: Session, shared: SharedAppState) {
        self.session = session
        self.shared = shared
        self.persistenceManager = PersistenceManager(sessionID: session.id)
    }

    // MARK: - Lifecycle

    /// Loads session-scoped persisted state. Call when the view model is first created.
    /// The shared app state (llmKit, memories, usage) is loaded separately by `SharedAppState.loadPersistedState()`.
    func loadPersistedState() async {
        // Apply default tunings from shared (bundled defaults) so UI sliders start at something sensible.
        agentPollIntervals = shared.defaultAgentPollIntervals
        agentMaxToolCalls = shared.defaultAgentMaxToolCalls
        agentMessageDebounceIntervals = shared.defaultAgentMessageDebounceIntervals

        // Load per-session settings (assignments, tunings, flags) if they exist.
        do {
            if let state = try await persistenceManager.loadSessionState() {
                if !state.agentAssignments.isEmpty {
                    agentAssignments = state.agentAssignments
                }
                if !state.agentPollIntervals.isEmpty {
                    agentPollIntervals = state.agentPollIntervals
                }
                if !state.agentMaxToolCalls.isEmpty {
                    agentMaxToolCalls = state.agentMaxToolCalls
                }
                if !state.agentMessageDebounceIntervals.isEmpty {
                    agentMessageDebounceIntervals = state.agentMessageDebounceIntervals
                }
                toolsEnabled = state.toolsEnabled
                autoRunNextTask = state.autoRunNextTask
                autoRunInterruptedTasks = state.autoRunInterruptedTasks
            } else {
                // No per-session state — fall back to the shared default assignments (from
                // bundled defaults). New sessions get this the first time they're opened.
                agentAssignments = shared.defaultAgentAssignments
            }
        } catch {
            logger.error("Failed to load session state: \(error.localizedDescription)")
            agentAssignments = shared.defaultAgentAssignments
        }

        // Prune stale assignments that reference configurations that no longer exist.
        let validConfigIDs = Set(shared.llmKit.configurations.map(\.id))
        for (role, configID) in agentAssignments {
            if !validConfigIDs.contains(configID) {
                agentAssignments[role] = nil
                print("[AgentSmith] Cleared stale assignment in session \(session.name) for \(role.rawValue) → \(configID)")
            }
        }

        // Auto-heal missing required-role assignments by picking a valid config from
        // the catalog. Without this, deleting bundled "default smith / brown / jones"
        // configs leaves every session permanently stuck on "No configuration assigned"
        // because `defaultAgentAssignments` keeps pointing at the now-deleted bundled
        // ids and the prune above wipes them on every launch. By falling forward onto
        // any remaining valid catalog entry, new sessions and pruned-stale sessions
        // both come up with a working assignment that the user can customize via the
        // gear sheet (which clones-on-edit when shared across roles, so this never
        // accidentally entangles roles together).
        let validConfigs = shared.llmKit.configurations.filter(\.isValid)
        if let fallback = validConfigs.first {
            for role in AgentRole.requiredRoles where agentAssignments[role] == nil {
                agentAssignments[role] = fallback.id
                print("[AgentSmith] Auto-assigned \(role.rawValue) → \(fallback.name) (\(fallback.id)) in session \(session.name)")
            }
        }

        // Load message history for up-arrow recall (per-session).
        if let data = UserDefaults.standard.data(forKey: sessionHistoryKey),
           let history = try? JSONDecoder().decode([String].self, from: data) {
            messageHistory = history
        }

        // Load channel log.
        do {
            var savedMessages = try await persistenceManager.loadChannelLog()
            // One-time migration: strip file_write diff metadata. See previous implementation
            // for rationale — this was a data-format cleanup that's idempotent on rerun.
            var strippedCount = 0
            for i in savedMessages.indices {
                guard var md = savedMessages[i].metadata else { continue }
                var changed = false
                if md.removeValue(forKey: "fileWriteOldContent") != nil { changed = true }
                if md.removeValue(forKey: "fileWriteContent") != nil { changed = true }
                if changed {
                    savedMessages[i].metadata = md
                    strippedCount += 1
                }
            }
            if strippedCount > 0 {
                print("[AgentSmith] Stripped stale file_write diff metadata from \(strippedCount) message(s) in session \(session.name); re-saving channel log.")
                do {
                    try await persistenceManager.saveChannelLog(savedMessages)
                } catch {
                    logger.error("Failed to re-save channel log after migration: \(error)")
                }
            }
            allPersistedMessages = savedMessages
            persistedHistoryCount = savedMessages.count
        } catch {
            let msg = "Failed to load channel log: \(error)"
            print("[AgentSmith] \(msg)")
            shared.startupError = msg
        }

        // Load tasks with status corrections.
        do {
            var savedTasks = try await persistenceManager.loadTasks()
            var anyStatusChanged = false
            for i in savedTasks.indices {
                if savedTasks[i].status == .running {
                    savedTasks[i].status = .interrupted
                    savedTasks[i].updatedAt = Date()
                    anyStatusChanged = true
                }
            }
            let cutoff = Date().addingTimeInterval(-4 * 3600)
            var anyArchived = false
            for i in savedTasks.indices {
                if savedTasks[i].status == .completed,
                   savedTasks[i].disposition == .active,
                   savedTasks[i].updatedAt < cutoff {
                    savedTasks[i].disposition = .archived
                    anyArchived = true
                }
            }
            tasks = savedTasks
            if anyArchived || anyStatusChanged { persistTasks() }

            let standaloneStore = TaskStore()
            taskStore = standaloneStore
            await standaloneStore.restore(savedTasks)
            await standaloneStore.setOnChange { [weak self, weak standaloneStore] in
                Task { @MainActor [weak self, weak standaloneStore] in
                    guard let self, let store = standaloneStore else { return }
                    let allTasks = await store.allTasks()
                    self.tasks = allTasks
                    self.persistTasks()
                }
            }
        } catch {
            let msg = "Failed to load tasks: \(error)"
            print("[AgentSmith] \(msg)")
            shared.startupError = msg
        }

        // Load timer history (timer_events.json) for the Timers history pane. Failure here
        // is non-fatal — an empty timer history just means "first run" or a corrupted file we
        // can rebuild as new events come in.
        do {
            let savedEvents = try await persistenceManager.loadTimerEvents()
            timerHistory = savedEvents.sorted { $0.timestamp > $1.timestamp }
        } catch {
            logger.error("Failed to load timer events: \(error.localizedDescription)")
        }

        // Load persisted scheduled wakes so reminders survive app restart. The list is
        // replayed onto Smith's actor in `start()` before the run loop begins, so any
        // wakes whose `wakeAt` already elapsed during downtime fire on the first loop
        // iteration. Empty list is the normal case for a fresh session.
        do {
            persistedWakesSnapshot = try await persistenceManager.loadScheduledWakes()
        } catch {
            logger.error("Failed to load scheduled wakes: \(error.localizedDescription)")
            persistedWakesSnapshot = []
        }

        hasLoadedPersistedState = true
    }

    /// Starts this session's runtime with its per-session agent assignments.
    func start() async {
        guard !isRunning else { return }
        guard !isAborted else { return }

        let missingRoles = AgentRole.requiredRoles.filter { agentAssignments[$0] == nil }
        if !missingRoles.isEmpty {
            let names = missingRoles.map(\.displayName).joined(separator: ", ")
            shared.startupError = "Cannot start — missing configuration for: \(names)"
            return
        }

        var providers: [AgentRole: any LLMProvider] = [:]
        var configurations: [AgentRole: ModelConfiguration] = [:]
        var apiTypes: [AgentRole: ProviderAPIType] = [:]
        for role in AgentRole.allCases {
            guard let configID = agentAssignments[role] else { continue }
            do {
                providers[role] = try shared.llmKit.makeProvider(for: configID)
            } catch {
                shared.startupError = "Failed to create provider for \(role.displayName): \(error.localizedDescription)"
                return
            }
            if let modelConfig = shared.llmKit.configurations.first(where: { $0.id == configID }) {
                configurations[role] = modelConfig
                if let modelProvider = shared.llmKit.providers.first(where: { $0.id == modelConfig.providerID }) {
                    apiTypes[role] = modelProvider.apiType
                }
            }
        }

        var tuning: [AgentRole: AgentTuningConfig] = [:]
        for role in AgentRole.allCases {
            tuning[role] = AgentTuningConfig(
                pollInterval: agentPollIntervals[role] ?? 5,
                maxToolCalls: agentMaxToolCalls[role] ?? 100,
                messageDebounceInterval: agentMessageDebounceIntervals[role] ?? 1
            )
        }

        // Prepare the shared semantic engine (idempotent — only pays cost on first start across all sessions).
        let engine: SemanticSearchEngine
        do {
            engine = try await shared.ensureSemanticEngine()
        } catch {
            let msg = "Failed to prepare embedding model: \(error.localizedDescription)"
            print("[AgentSmith] \(msg)")
            shared.startupError = msg
            return
        }

        // Ensure shared memory store is loaded (runs re-embedding migrations exactly once).
        let sharedMemoryStore: MemoryStore
        do {
            sharedMemoryStore = try await shared.ensureMemoryStore()
        } catch {
            let msg = "Failed to prepare memory store: \(error.localizedDescription)"
            print("[AgentSmith] \(msg)")
            shared.startupError = msg
            return
        }

        let newRuntime = OrchestrationRuntime(
            providers: providers,
            configurations: configurations,
            providerAPITypes: apiTypes,
            agentTuning: tuning,
            semanticSearchEngine: engine,
            usageStore: shared.usageStore,
            autoAdvanceEnabled: autoRunNextTask,
            autoRunInterruptedTasks: autoRunInterruptedTasks,
            memoryStore: sharedMemoryStore
        )
        runtime = newRuntime
        isRunning = true

        if !tasks.isEmpty {
            let tasksToRestore = tasks
            await newRuntime.taskStore.restore(tasksToRestore)
        }

        await newRuntime.setOnAbort { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAborted = true
                self.abortReason = reason
                self.isRunning = false
                self.processingRoles.removeAll()
                self.agentToolNames.removeAll()
                self.inspectorStore.clearAll()
                self.runtime = nil
            }
        }

        await newRuntime.setOnProcessingStateChange { [weak self] role, isProcessing in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isProcessing {
                    self.processingRoles.insert(role)
                } else {
                    self.processingRoles.remove(role)
                }
            }
        }

        await newRuntime.setOnAgentStarted { [weak self] role, toolNames in
            Task { @MainActor [weak self] in
                self?.agentToolNames[role] = toolNames
            }
        }

        let channel = await newRuntime.channel
        channelStreamTask = Task { @MainActor [weak self] in
            for await message in await channel.stream() {
                guard let self else { break }
                self.messages.append(message)
                self.allPersistedMessages.append(message)
                self.shared.speechController.handle(message)
                self.persistMessages()
            }
        }

        let liveTaskStore = await newRuntime.taskStore
        self.taskStore = liveTaskStore
        await liveTaskStore.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allTasks = await liveTaskStore.allTasks()
                self.tasks = allTasks
                self.persistTasks()
            }
        }

        await liveTaskStore.archiveStaleCompleted()

        await newRuntime.setOnTurnRecorded { [weak self] role, turn in
            Task { @MainActor [weak self] in
                self?.inspectorStore.appendTurn(turn, for: role)
            }
        }

        await newRuntime.setOnContextChanged { [weak self] role, messages in
            Task { @MainActor [weak self] in
                self?.inspectorStore.updateLiveContext(messages, for: role)
            }
        }

        await newRuntime.setOnEvaluationRecorded { [weak self] record in
            Task { @MainActor [weak self] in
                self?.inspectorStore.appendEvaluation(record)
            }
        }

        // Restore prior timer history into the runtime's event log so subsequent appends
        // join an existing series rather than start fresh on each launch.
        let priorEvents = timerHistory
        let eventLog = await newRuntime.timerEventLog
        if !priorEvents.isEmpty {
            await eventLog.restore(priorEvents)
        }
        await eventLog.setOnChange { [weak self, weak eventLog] in
            Task { @MainActor [weak self, weak eventLog] in
                guard let self, let log = eventLog else { return }
                let snapshot = await log.allEvents()
                self.timerHistory = snapshot
                self.persistTimerEvents(snapshot)
            }
        }

        // Surface timer events into the channel as system messages when the user has the
        // Debug → Show Timer Activity toggle enabled, and snapshot the wake list to disk
        // on every lifecycle event so reminders survive an app quit. We snapshot here
        // (rather than only on `.scheduled`) because cancellations and fires also mutate
        // the in-memory list (cancellation removes a wake; recurrence-fire replaces one
        // wake with the next-occurrence wake).
        await newRuntime.setOnTimerEventForChannel { [weak self] event in
            await MainActor.run {
                guard let self else { return }
                if self.shared.showTimerActivityInTranscript {
                    let line = AppViewModel.transcriptLine(for: event)
                    Task { @MainActor [weak self] in
                        guard let self, let runtime = self.runtime else { return }
                        let channel = await runtime.channel
                        await channel.post(ChannelMessage(
                            sender: .system,
                            content: line,
                            metadata: [
                                "messageKind": .string("timer_activity"),
                                "timerEventID": .string(event.id.uuidString)
                            ]
                        ))
                    }
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.snapshotAndPersistWakes()
                }
            }
        }

        // Replay wakes that survived a prior quit. We do this BEFORE `start()` so any wake
        // whose `wakeAt` is already in the past fires on the first loop iteration — the
        // user's "remind me at 9pm daily" doesn't silently miss days because the app was
        // closed. After replay we drop the snapshot; subsequent persistence is driven by
        // `onTimerEventForChannel` (every schedule/fire/cancel triggers a fresh snapshot).
        if !persistedWakesSnapshot.isEmpty {
            await newRuntime.restoreScheduledWakes(persistedWakesSnapshot)
            persistedWakesSnapshot = []
        }

        await newRuntime.start()

        // After Smith starts the active-timers list may already contain restored wakes for
        // .scheduled tasks — refresh once so the View → Timers panel shows them.
        await refreshActiveTimers()
    }

    /// Re-reads the currently-active wakes from Smith. Cheap; the agent stores the list
    /// in-memory and there are typically only a handful at any time.
    func refreshActiveTimers() async {
        guard let runtime else {
            activeTimers = []
            return
        }
        activeTimers = await runtime.currentScheduledWakes()
    }

    /// Cancels a scheduled timer by id. Returns true if anything was cancelled.
    @discardableResult
    func cancelTimer(id: UUID) async -> Bool {
        guard let runtime else { return false }
        let cancelled = await runtime.cancelScheduledWake(id: id)
        if cancelled { await refreshActiveTimers() }
        return cancelled
    }

    /// Renders a single transcript line for a timer event when the Debug toggle is on.
    private static func transcriptLine(for event: TimerEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let scheduledStr: String = {
            guard let d = event.scheduledFireAt else { return "" }
            return formatter.string(from: d)
        }()
        switch event.kind {
        case .scheduled:
            let recur = event.recurrenceDescription.map { " (\($0))" } ?? ""
            let task = event.taskID.map { " task=\($0.uuidString.prefix(8))" } ?? ""
            return "[Timer] scheduled at \(scheduledStr)\(task)\(recur): \(event.instructions)"
        case .fired:
            let coalesced = event.coalescedCount.map { " (+\($0 - 1) more)" } ?? ""
            return "[Timer] fired at \(scheduledStr)\(coalesced): \(event.instructions)"
        case .cancelled:
            let cause = event.cancellationCause?.rawValue ?? "unknown"
            return "[Timer] cancelled (\(cause)): \(event.instructions)"
        }
    }

    private func persistTimerEvents(_ events: [TimerEvent]) {
        Task.detached { [persistenceManager, logger] in
            do {
                try await persistenceManager.saveTimerEvents(events)
            } catch {
                logger.error("Failed to save timer events: \(error)")
            }
        }
    }

    /// Snapshots the runtime's current wake list and writes it to disk. Also refreshes the
    /// `activeTimers` published property so the View → Timers panel updates immediately.
    /// Called from the `onTimerEventForChannel` callback on every schedule/fire/cancel.
    private func snapshotAndPersistWakes() async {
        guard let runtime else { return }
        let wakes = await runtime.currentScheduledWakes()
        activeTimers = wakes
        let snapshot = wakes
        Task.detached { [persistenceManager, logger] in
            do {
                try await persistenceManager.saveScheduledWakes(snapshot)
            } catch {
                logger.error("Failed to save scheduled wakes: \(error)")
            }
        }
    }

    /// Sends user input (with any pending attachments) to Smith.
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        if pendingAttachments.isEmpty, text.lowercased() == "/clear" {
            inputText = ""
            clearLog()
            return
        }

        guard let runtime else { return }

        let attachments = pendingAttachments
        inputText = ""
        pendingAttachments = []

        if !text.isEmpty {
            if messageHistory.last != text {
                messageHistory.append(text)
            }
            if messageHistory.count > Self.maxMessageHistory {
                messageHistory.removeFirst(messageHistory.count - Self.maxMessageHistory)
            }
            historyIndex = -1
            historyStash = ""
            persistMessageHistory()
        }

        for attachment in attachments {
            Task.detached { [persistenceManager, logger] in
                do {
                    try await persistenceManager.saveAttachment(attachment)
                } catch {
                    logger.error("Failed to save attachment \(attachment.filename): \(error)")
                }
            }
        }

        await runtime.sendUserMessage(text, attachments: attachments)
    }

    enum HistoryDirection { case up, down }

    @discardableResult
    func navigateHistory(_ direction: HistoryDirection) -> Bool {
        guard !messageHistory.isEmpty else { return false }
        switch direction {
        case .up:
            if historyIndex == -1 {
                historyStash = inputText
                historyIndex = messageHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            } else {
                return false
            }
            inputText = messageHistory[historyIndex]
            return true
        case .down:
            guard historyIndex >= 0 else { return false }
            if historyIndex < messageHistory.count - 1 {
                historyIndex += 1
                inputText = messageHistory[historyIndex]
            } else {
                historyIndex = -1
                inputText = historyStash
                historyStash = ""
            }
            return true
        }
    }

    func sendDirectMessage(to role: AgentRole, text: String) async {
        guard let runtime else { return }
        await runtime.sendDirectMessage(to: role, text: text)
    }

    func updateSystemPrompt(for role: AgentRole, prompt: String) async {
        guard let runtime else { return }
        await runtime.updateSystemPrompt(for: role, prompt: prompt)
    }

    // MARK: - Task actions

    func archiveTask(id: UUID) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.archive(id: id)
        if !succeeded {
            taskActionError = "This task is in progress and cannot be archived."
        }
    }

    func deleteTask(id: UUID) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.softDelete(id: id)
        if !succeeded {
            taskActionError = "This task is in progress and cannot be deleted."
        }
    }

    func unarchiveTask(id: UUID) async {
        await taskStore?.unarchive(id: id)
    }

    func undeleteTask(id: UUID) async {
        await taskStore?.undelete(id: id)
    }

    func permanentlyDeleteTask(id: UUID) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.permanentlyDelete(id: id)
        if !succeeded {
            taskActionError = "This task is in progress and cannot be permanently deleted."
        }
    }

    func updateTaskDescription(id: UUID, description: String) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.updateDescription(id: id, description: description)
        if !succeeded {
            taskActionError = "Only pending, paused, or interrupted tasks can be edited."
        }
    }

    func pauseTask(id: UUID) async {
        await runtime?.terminateTaskAgents(taskID: id)
        await taskStore?.pause(id: id)
    }

    func stopTask(id: UUID) async {
        await runtime?.terminateTaskAgents(taskID: id)
        await taskStore?.stop(id: id)
    }

    func retryTask(_ task: AgentTask) async {
        await taskStore?.softDelete(id: task.id)
        await sendDirectMessage(
            to: .smith,
            text: "Please retry this failed task:\nTitle: \(task.title)\nDescription: \(task.description)\nID: \(task.id.uuidString)"
        )
    }

    func runTaskAgain(_ task: AgentTask) async {
        await taskStore?.archive(id: task.id)
        await sendDirectMessage(
            to: .smith,
            text: "Please run this task again:\nTitle: \(task.title)\nDescription: \(task.description)\nID: \(task.id.uuidString)"
        )
    }

    func updatePollInterval(for role: AgentRole, interval: TimeInterval) async {
        agentPollIntervals[role] = interval
        guard let runtime else { return }
        await runtime.updatePollInterval(for: role, interval: interval)
    }

    func updateMaxToolCalls(for role: AgentRole, count: Int) async {
        agentMaxToolCalls[role] = count
        guard let runtime else { return }
        await runtime.updateMaxToolCalls(for: role, count: count)
    }

    func stopCurrentTask() async {
        guard let runningTask = tasks.first(where: { $0.status == .running }) else { return }
        await stopTask(id: runningTask.id)
    }

    /// Stops this session only. For app-wide Emergency Stop, SessionManager iterates all sessions.
    ///
    /// Does NOT call `shared.speechController.stopAll()` because the SpeechController is
    /// shared across sessions — stopping it would silence speech in other running tabs.
    /// Any in-progress utterance from this session's agents will finish naturally; no new
    /// utterances get queued after this point because the runtime has stopped.
    func stopAll() async {
        guard let runtime else { return }
        await runtime.stopAll()
        isRunning = false
        processingRoles.removeAll()
        agentToolNames.removeAll()
        inspectorStore.clearAll()
        channelStreamTask?.cancel()
        channelStreamTask = nil
        self.runtime = nil

        if let store = taskStore {
            let liveTasks = await store.allTasks()
            for task in liveTasks where task.status == .running {
                await store.updateStatus(id: task.id, status: .interrupted)
            }
        }

        // Flush persistence synchronously here so callers can rely on no pending writes
        // racing whatever they do next (e.g. quitting the app, reading the session's files
        // for diagnostics). The hot-path persists during message streaming still use
        // detached tasks for performance; this is the quiescent, stop-of-world flush.
        await flushPersistence()
        await shared.usageStore.flush()
    }

    /// Awaits any pending channel-log and tasks writes so the on-disk state reflects the
    /// current in-memory state before `stopAll` returns. Called at the end of `stopAll` so
    /// that session deletion can proceed without racing detached saves.
    private func flushPersistence() async {
        let snapshot = allPersistedMessages
        let tasksToSave = tasks
        do {
            try await persistenceManager.saveChannelLog(snapshot)
            try await persistenceManager.saveTasks(tasksToSave)
        } catch {
            logger.error("Failed to flush persistence on stop: \(error.localizedDescription)")
        }
    }

    func resetAbort() {
        isAborted = false
        abortReason = ""
    }

    func clearLog() {
        messages.removeAll()
        inspectorStore.clearAll()
    }

    func restoreHistory() {
        let currentIDs = Set(messages.map(\.id))
        let restoredHistory = allPersistedMessages.filter { !currentIDs.contains($0.id) }
        messages = restoredHistory + messages
        hasRestoredHistory = true
    }

    // MARK: - Attachments

    func addAttachments(from urls: [URL]) {
        for url in urls {
            let didAccessScope = url.startAccessingSecurityScopedResource()
            defer {
                if didAccessScope { url.stopAccessingSecurityScopedResource() }
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                print("[AgentSmith] Failed to read attachment \(url.lastPathComponent): \(error)")
                continue
            }
            let mimeType = Self.mimeType(for: url)
            let attachment = Attachment(
                filename: url.lastPathComponent,
                mimeType: mimeType,
                byteCount: data.count,
                data: data
            )
            pendingAttachments.append(attachment)
        }
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func addAttachment(data: Data, filename: String, mimeType: String) {
        let attachment = Attachment(
            filename: filename,
            mimeType: mimeType,
            byteCount: data.count,
            data: data
        )
        pendingAttachments.append(attachment)
    }

    func pasteFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            addAttachments(from: urls)
            return true
        }
        if let tiffData = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            addAttachment(
                data: pngData,
                filename: "Pasted Image \(Self.attachmentTimestamp()).png",
                mimeType: "image/png"
            )
            return true
        }
        return false
    }

    static func attachmentTimestamp() -> String {
        attachmentTimestampFormatter.string(from: Date())
    }

    private static let attachmentTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    // MARK: - Configuration helpers (per-session)

    /// Resolves each agent role to its assigned ModelConfiguration, for inspector display.
    var resolvedAgentConfigs: [AgentRole: ModelConfiguration] {
        var result: [AgentRole: ModelConfiguration] = [:]
        for (role, configID) in agentAssignments {
            if let config = shared.llmKit.configurations.first(where: { $0.id == configID }) {
                result[role] = config
            }
        }
        return result
    }

    /// Whether all required agent roles in this session have valid assigned configurations.
    var allAgentConfigsValid: Bool {
        AgentRole.requiredRoles.allSatisfy { role in
            guard let configID = agentAssignments[role],
                  let config = shared.llmKit.configurations.first(where: { $0.id == configID }),
                  config.isValid else { return false }
            return true
        }
    }

    /// Clears any assignment in this session that references the deleted config ID.
    func clearAssignment(forConfigID id: UUID) {
        for (role, configID) in agentAssignments where configID == id {
            agentAssignments[role] = nil
        }
    }

    /// Returns a `ModelConfiguration` dedicated to this role within this session.
    ///
    /// Creates or clones as needed so edits to the returned config don't affect this session's
    /// other roles. Edits *may* affect roles in other sessions that point at the same config —
    /// the config catalog is global and sessions can intentionally share configs. Users wanting
    /// full isolation can duplicate the config via Settings → Configurations.
    @discardableResult
    func ensureDedicatedConfig(for role: AgentRole) -> ModelConfiguration {
        if let existingID = agentAssignments[role],
           let existing = shared.llmKit.configurations.first(where: { $0.id == existingID }) {
            let sharedWithinSession = agentAssignments.filter { $0.value == existingID && $0.key != role }
            if sharedWithinSession.isEmpty {
                return existing
            }
            var clone = existing
            clone.id = UUID()
            clone.name = "\(role.displayName) — \(existing.modelID)"
            shared.llmKit.addConfiguration(clone)
            agentAssignments[role] = clone.id
            return clone
        }

        let starter: ModelConfiguration
        if let firstProvider = shared.llmKit.providers.first {
            starter = ModelConfiguration(
                id: UUID(),
                name: "\(role.displayName) — \(firstProvider.name)",
                providerID: firstProvider.id,
                modelID: "",
                temperature: 0.7,
                maxOutputTokens: 4096,
                maxContextTokens: 128_000
            )
        } else {
            starter = ModelConfiguration(
                id: UUID(),
                name: "\(role.displayName)",
                providerID: "",
                modelID: ""
            )
        }
        shared.llmKit.addConfiguration(starter)
        agentAssignments[role] = starter.id
        return starter
    }

    // MARK: - Private

    private var sessionHistoryKey: String {
        "messageHistory.\(session.id.uuidString)"
    }

    private func persistMessageHistory() {
        do {
            let data = try JSONEncoder().encode(messageHistory)
            UserDefaults.standard.set(data, forKey: sessionHistoryKey)
        } catch {
            logger.error("Failed to encode message history: \(error)")
        }
    }

    private func persistMessages() {
        let snapshot = allPersistedMessages
        Task.detached { [persistenceManager, logger] in
            do {
                try await persistenceManager.saveChannelLog(snapshot)
            } catch {
                logger.error("Failed to persist messages: \(error)")
            }
        }
    }

    private func persistTasks() {
        let tasksToSave = tasks
        Task.detached { [persistenceManager, logger] in
            do {
                try await persistenceManager.saveTasks(tasksToSave)
            } catch {
                logger.error("Failed to persist tasks: \(error)")
            }
        }
    }

    private func persistSessionStateAsync() {
        let state = SessionState(
            agentAssignments: agentAssignments,
            agentPollIntervals: agentPollIntervals,
            agentMaxToolCalls: agentMaxToolCalls,
            agentMessageDebounceIntervals: agentMessageDebounceIntervals,
            toolsEnabled: toolsEnabled,
            autoRunNextTask: autoRunNextTask,
            autoRunInterruptedTasks: autoRunInterruptedTasks
        )
        Task.detached { [persistenceManager, logger] in
            do {
                try await persistenceManager.saveSessionState(state)
            } catch {
                logger.error("Failed to persist session state: \(error)")
            }
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
