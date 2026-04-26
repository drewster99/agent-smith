import Foundation
import SemanticSearch

/// Thread-safe set for tracking files read during an agent session.
/// Used by FileEditTool to verify a file was read before editing.
final class FileReadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func record(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        paths.insert(path)
    }

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(path)
    }
}

/// Top-level runtime that owns all agents, the channel, and the task store.
public actor OrchestrationRuntime {
    public let channel: MessageChannel
    public let taskStore: TaskStore
    public let memoryStore: MemoryStore

    /// Fixed UUID representing the human user for private Smith→User messages.
    public static let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private var smith: AgentActor?
    private var smithID: UUID?
    private var agents: [UUID: AgentActor] = [:]

    /// Current Brown agent ID (only one active at a time).
    private var currentBrownID: UUID?
    /// Maps agent IDs to their roles for access-control lookups.
    private var agentRoles: [UUID: AgentRole] = [:]

    /// Archived snapshots of terminated agents, keyed by role for latest-wins semantics.
    private var terminatedAgentArchive: [AgentRole: AgentArchiveEntry] = [:]

    /// Active SecurityEvaluator for the current Brown, keyed by Brown's agent ID.
    private var securityEvaluators: [UUID: SecurityEvaluator] = [:]
    /// Preserved evaluation records from terminated Browns, for inspector display.
    private var archivedEvaluationRecords: [UUID: [EvaluationRecord]] = [:]

    /// Summarizer for generating task summaries after completion/failure.
    private var taskSummarizer: TaskSummarizer?

    private var llmProviders: [AgentRole: any LLMProvider]
    private var llmConfigs: [AgentRole: ModelConfiguration]
    private var providerAPITypes: [AgentRole: ProviderAPIType]
    private var agentTuning: [AgentRole: AgentTuningConfig]
    /// Whether Smith should automatically run the next pending task after completing one.
    /// Mutable so the user can toggle it at runtime via `setAutoAdvance(_:)`.
    public private(set) var autoAdvanceEnabled: Bool
    /// Whether interrupted tasks should be auto-resumed on launch.
    private let autoRunInterruptedTasks: Bool
    /// Persistent token usage tracking across all agents.
    public let usageStore: UsageStore
    /// Append-only log of timer lifecycle events. Populated from `AgentActor`'s timer
    /// callbacks; surfaced in the View → Timers history pane.
    public let timerEventLog: TimerEventLog
    private var monitoringTimer: MonitoringTimer?
    private var powerManager: PowerAssertionManager?
    /// Maps each agent ID to its channel subscription IDs for proper cleanup.
    private var agentSubscriptions: [UUID: [UUID]] = [:]

    /// Identifier for the current contiguous run of the runtime. Set fresh each time
    /// `start()` is called and cleared on `stop()` / `abort()`. Stamped on every
    /// UsageRecord and ChannelMessage produced during the run so queries can group
    /// by session without having to join timestamps to a separate session log.
    public private(set) var currentSessionID: UUID?

    /// Set by Jones abort — prevents restart until user clears it.
    private var aborted = false
    /// Callback to notify the app layer when abort is triggered.
    private var onAbort: (@Sendable (String) -> Void)?
    /// Callback to notify the app layer when an agent starts or stops an LLM call.
    private var onProcessingStateChange: (@Sendable (AgentRole, Bool) -> Void)?
    /// Callback fired when an agent comes online, passing its role and configured tool names.
    private var onAgentStarted: (@Sendable (AgentRole, [String]) -> Void)?
    /// Callback fired when an agent records a new LLM turn, for incremental UI updates.
    private var onTurnRecorded: (@Sendable (AgentRole, LLMTurnRecord) -> Void)?
    /// Callback fired when a security evaluation is recorded, for incremental UI updates.
    private var onEvaluationRecorded: (@Sendable (EvaluationRecord) -> Void)?
    /// Callback fired when an agent's conversation history changes, for live inspector updates.
    private var onContextChanged: (@Sendable (AgentRole, [LLMMessage]) -> Void)?
    /// Optional hook the app layer wires to surface timer events as system messages in the
    /// channel transcript when the user has the Debug → Show Timer Activity toggle on. Async
    /// because the app layer may need to hop to MainActor to read the user-defaults flag.
    private var onTimerEventForChannel: (@Sendable (TimerEvent) async -> Void)?

    public func setOnTimerEventForChannel(_ handler: @escaping @Sendable (TimerEvent) async -> Void) {
        onTimerEventForChannel = handler
    }

    public func currentScheduledWakes() async -> [ScheduledWake] {
        await smith?.listScheduledWakes() ?? []
    }

    public func cancelScheduledWake(id: UUID) async -> Bool {
        await smith?.cancelWake(id: id) ?? false
    }

    /// Replays a previously-persisted set of wakes onto Smith's actor. Called by the app
    /// layer at cold-launch *before* `start()` so any wake that elapsed while the app was
    /// quit fires on the next loop iteration. Replacing rather than merging is intentional:
    /// after this call the actor's wake list IS the persisted snapshot.
    public func restoreScheduledWakes(_ wakes: [ScheduledWake]) async {
        await smith?.restoreScheduledWakes(wakes)
    }

    public init(
        providers: [AgentRole: any LLMProvider],
        configurations: [AgentRole: ModelConfiguration],
        providerAPITypes: [AgentRole: ProviderAPIType] = [:],
        agentTuning: [AgentRole: AgentTuningConfig] = [:],
        semanticSearchEngine: SemanticSearchEngine,
        usageStore: UsageStore,
        autoAdvanceEnabled: Bool = true,
        autoRunInterruptedTasks: Bool = false,
        memoryStore: MemoryStore? = nil
    ) {
        self.channel = MessageChannel()
        self.taskStore = TaskStore()
        self.memoryStore = memoryStore ?? MemoryStore(engine: semanticSearchEngine)
        self.llmProviders = providers
        self.llmConfigs = configurations
        self.providerAPITypes = providerAPITypes
        self.agentTuning = agentTuning
        self.autoAdvanceEnabled = autoAdvanceEnabled
        self.autoRunInterruptedTasks = autoRunInterruptedTasks
        self.usageStore = usageStore
        self.timerEventLog = TimerEventLog()
    }

    /// Updates the auto-advance setting at runtime so it takes effect immediately.
    public func setAutoAdvance(_ enabled: Bool) {
        autoAdvanceEnabled = enabled
    }

    /// Registers a callback fired when Jones triggers an abort.
    public func setOnAbort(_ handler: @escaping @Sendable (String) -> Void) {
        onAbort = handler
    }

    /// Registers a callback fired when an agent starts or stops an LLM API call.
    public func setOnProcessingStateChange(_ handler: @escaping @Sendable (AgentRole, Bool) -> Void) {
        onProcessingStateChange = handler
    }

    /// Registers a callback fired when an agent comes online, with its role and tool names.
    public func setOnAgentStarted(_ handler: @escaping @Sendable (AgentRole, [String]) -> Void) {
        onAgentStarted = handler
    }

    /// Registers a callback fired when any agent records a new LLM turn.
    public func setOnTurnRecorded(_ handler: @escaping @Sendable (AgentRole, LLMTurnRecord) -> Void) {
        onTurnRecorded = handler
    }

    /// Registers a callback fired when a security evaluation is recorded.
    public func setOnEvaluationRecorded(_ handler: @escaping @Sendable (EvaluationRecord) -> Void) {
        onEvaluationRecorded = handler
    }

    /// Registers a callback fired when an agent's conversation history changes.
    public func setOnContextChanged(_ handler: @escaping @Sendable (AgentRole, [LLMMessage]) -> Void) {
        onContextChanged = handler
    }

    /// Whether the system has been aborted by Jones.
    public var isAborted: Bool { aborted }

    /// Clears the abort state so the system can be restarted.
    public func resetAbort() {
        aborted = false
    }

    /// Returns the role of the agent with the given ID, if it exists.
    public func roleForAgent(id: UUID) -> AgentRole? {
        agentRoles[id]
    }

    /// Returns the currently active UUID for the given role, or nil if no such agent is running.
    public func agentIDForRole(_ role: AgentRole) -> UUID? {
        agentRoles.first(where: { $0.value == role })?.key
    }

    /// Triggers a full system restart for a newly-created task.
    /// Launches a detached task so the calling agent's tool execution can unwind
    /// without deadlocking (the caller is running inside this actor).
    /// Captures the last user message before stopping so it can be forwarded to the new Smith.
    public func restartForNewTask(taskID: UUID) {
        Task.detached { [weak self] in
            guard let self else { return }
            // Capture the most recent user message before stopping — it may contain
            // permissions or instructions that would be lost across the restart.
            let lastUserMessage = await self.captureLastUserMessage()
            // Capture session ID before stopAll() clears it — needed to attribute
            // Smith's pre-task planning calls to the task they produced.
            let priorSessionID = await self.currentSessionID
            await self.stopAll()
            // Backfill nil-taskID records from the prior session onto the new task.
            // All agent loops have exited by now, so every record has been written.
            if let priorSessionID {
                await self.usageStore.backfillTaskID(taskID, forSession: priorSessionID)
            }
            await self.start(resumingTaskID: taskID, lastUserMessage: lastUserMessage)
        }
    }

    /// Returns the content of the most recent user message that Smith has not yet
    /// acknowledged, if any. A user message is considered acknowledged once Smith
    /// has posted any Smith→user message after it, so we avoid re-forwarding
    /// already-answered requests across a restart.
    private func captureLastUserMessage() async -> String? {
        let messages = await channel.allMessages()
        for message in messages.reversed() {
            if case .agent(.smith) = message.sender,
               case .user = message.recipient {
                // Hit Smith's most recent reply to the user without finding a
                // newer user message — nothing unhandled to forward.
                return nil
            }
            if case .user = message.sender {
                return message.content
            }
        }
        return nil
    }

    /// Starts the Smith agent and the monitoring timer.
    /// - Parameter resumingTaskID: When set, skips the "ask user" preamble and immediately
    ///   instructs Smith to spawn Brown and begin work on this task.
    /// - Parameter lastUserMessage: The most recent user message captured before a restart,
    ///   included in the initial instruction so new Smith doesn't lose user context.
    public func start(resumingTaskID: UUID? = nil, lastUserMessage: String? = nil) async {
        guard smith == nil else { return }
        guard !aborted else { return }

        // Mint a fresh session ID for this run. Propagated to every agent, evaluator,
        // and summarizer so their UsageRecords carry it, and published to the
        // MessageChannel so every posted message is auto-stamped with the session.
        let sessionID = UUID()
        currentSessionID = sessionID
        await channel.setCurrentSessionID(sessionID)

        let powerMgr = PowerAssertionManager(taskStore: taskStore)
        await powerMgr.start()
        powerManager = powerMgr

        // Create the TaskSummarizer only if a summarizer model is explicitly configured.
        // If not configured, task summarization is silently skipped.
        if let summarizerProvider = llmProviders[.summarizer],
           let summarizerConfig = llmConfigs[.summarizer] {
            taskSummarizer = TaskSummarizer(
                provider: summarizerProvider,
                memoryStore: memoryStore,
                channel: channel,
                contextWindowSize: summarizerConfig.contextWindowSize,
                maxOutputTokens: summarizerConfig.maxTokens,
                usageStore: usageStore,
                configuration: summarizerConfig,
                providerType: providerAPITypes[.summarizer]?.rawValue ?? "",
                sessionID: sessionID
            )
        } else {
            taskSummarizer = nil
        }

        guard let smithConfig = llmConfigs[.smith],
              let provider = llmProviders[.smith] else {
            await channel.post(ChannelMessage(sender: .system, content: "No Smith provider configured — cannot start."))
            return
        }

        let id = UUID()
        smithID = id
        let followUpScheduler = FollowUpScheduler()
        let context = makeToolContext(agentID: id, role: .smith, followUpScheduler: followUpScheduler, currentResumingTaskID: resumingTaskID)

        // Smith only wakes for: private messages (user/Brown/Jones→Smith), system termination notices.
        // Public Brown messages, tool_request/tool execution messages, and security review notices
        // are completely filtered out — they generate too much noise and don't need Smith's attention.
        let smithMessageFilter: @Sendable (ChannelMessage) -> Bool = { message in
            // Drop Smith's own outgoing messages — they are published to the channel and would
            // immediately re-wake Smith, producing an infinite loop of repeated messages.
            if case .agent(let role) = message.sender, role == .smith {
                return false
            }
            // Drop all public messages from Brown, Jones, or Summarizer, except online
            // announcements which Smith needs for coordination. Summarizer results are
            // persisted to the memory store and task record — Smith doesn't need them
            // in its conversation history (and they can distract from pending user messages).
            if case .agent(let role) = message.sender, message.recipientID == nil,
               role == .brown || role == .jones || role == .summarizer {
                guard case .string(let kind) = message.metadata?["messageKind"],
                      kind == "agent_online" else { return false }
            }
            // Drop tool_request messages (Brown's approval requests).
            if case .string(let kind) = message.metadata?["messageKind"], kind == "tool_request" {
                return false
            }
            // Drop tool execution trace messages.
            if message.metadata?["tool"] != nil {
                return false
            }
            // For system messages, only pass through diagnostics directly relevant to Smith:
            // agent lifecycle events (errors, termination), rate-limit notices, and
            // system guidance injected by tools (e.g., task_update_guidance).
            if case .system = message.sender {
                if case .string(let kind) = message.metadata?["messageKind"],
                   kind == "task_update_guidance" {
                    // Always pass through — this is system guidance for Smith.
                } else {
                    let c = message.content
                    guard c.hasPrefix("Agent ") || c.hasPrefix("Rate limit:") else { return false }
                }
            }
            return true
        }

        let smithAgent = AgentActor(
            id: id,
            configuration: AgentConfiguration(
                role: .smith,
                llmConfig: smithConfig,
                providerAPIType: providerAPITypes[.smith] ?? .openAICompatible,
                systemPrompt: SmithBehavior.systemPrompt(autoAdvanceEnabled: autoAdvanceEnabled),
                toolNames: SmithBehavior.toolNames,
                suppressesRawTextToChannel: true,
                pollInterval: agentTuning[.smith]?.pollInterval ?? 20,
                messageDebounceInterval: agentTuning[.smith]?.messageDebounceInterval ?? 1,
                messageAcceptFilter: smithMessageFilter,
                maxToolCallsPerIteration: agentTuning[.smith]?.maxToolCalls ?? 100
            ),
            provider: provider,
            tools: SmithBehavior.tools(),
            toolContext: context
        )
        await followUpScheduler.set(agent: smithAgent)
        await smithAgent.setUsageStore(usageStore)
        await smithAgent.setSessionID(currentSessionID)
        if let turnCallback = onTurnRecorded {
            await smithAgent.setOnTurnRecorded { turn in turnCallback(.smith, turn) }
        }
        if let contextCallback = onContextChanged {
            await smithAgent.setOnContextChanged { messages in contextCallback(.smith, messages) }
        }
        // Brown-activity digest assembler: pulls recent channel messages since the cutoff and
        // formats a brief summary that Smith can react to without polling. Returns nil when
        // there's no Brown alive to summarize OR when the window contains no fresh activity —
        // either way the digest is suppressed. Gating on Brown's presence avoids the misleading
        // "Brown made 0 tool calls — likely deep in tool work or stuck" message that fires when
        // no Brown exists at all.
        let digestChannel = channel
        await smithAgent.setSmithDigestProvider { [weak self, weak digestChannel] since in
            guard let self, let digestChannel else { return nil }
            let brownAlive = await self.agentIDForRole(.brown) != nil
            guard brownAlive else { return nil }
            return await Self.assembleBrownActivityDigest(channel: digestChannel, since: since)
        }
        // Cancel any task-scoped wakes when the task transitions to a terminal status the first time.
        let scheduler = followUpScheduler
        await taskStore.setOnTaskTerminated { taskID in
            Task { await scheduler.cancelWakesForTask(taskID) }
        }

        // Wire timer lifecycle callbacks from Smith's actor into the runtime's event log so
        // the timers UI / history view can render scheduled / fired / cancelled rows.
        let eventLog = timerEventLog
        let timerSurfaceContext = onTimerEventForChannel
        await smithAgent.setTimerCallbacks(
            onScheduled: { wake in
                Task {
                    let event = TimerEvent.scheduled(from: wake)
                    await eventLog.record(event)
                    await timerSurfaceContext?(event)
                }
            },
            onFired: { primary, all in
                Task {
                    let event = TimerEvent.fired(primary: primary, batchSize: all.count)
                    await eventLog.record(event)
                    await timerSurfaceContext?(event)
                }
            },
            onCancelled: { wake, cause in
                Task {
                    let event = TimerEvent.cancelled(wake: wake, cause: cause)
                    await eventLog.record(event)
                    await timerSurfaceContext?(event)
                }
            }
        )

        smith = smithAgent
        agents[id] = smithAgent
        agentRoles[id] = .smith

        let subID = await channel.subscribe { [weak smithAgent] message in
            guard let smithAgent else { return }
            Task { await smithAgent.receiveChannelMessage(message) }
        }
        agentSubscriptions[id] = [subID]

        // Mark any leftover running tasks as interrupted — no Brown is running them anymore.
        // (Clean shutdowns mark these interrupted via AppViewModel; this catches crashes/force-quits.)
        // Skip the resuming task if present — it will be set to running momentarily.
        let allTasks = await taskStore.allTasks()
        let activeTasks = allTasks.filter { $0.disposition == .active }
        let leftoverRunningTasks = activeTasks.filter { $0.status == .running && $0.id != resumingTaskID }
        for task in leftoverRunningTasks {
            await taskStore.updateStatus(id: task.id, status: .interrupted)
        }

        let initialInstruction: String

        // Fast path: restarting for a specific task (triggered by run_task).
        // Auto-spawn Brown, deliver task briefing, and tell Smith to monitor.
        if let resumingTaskID {
            if var resumingTask = await taskStore.task(id: resumingTaskID) {
                // Auto-spawn Brown and deliver the task briefing
                let brownSpawned: Bool
                if let brownID = await spawnBrown() {
                    await taskStore.updateStatus(id: resumingTaskID, status: .running)
                    await taskStore.assignAgent(taskID: resumingTaskID, agentID: brownID)
                    // Re-read to get the latest state (includes any amendments from run_task)
                    resumingTask = await taskStore.task(id: resumingTaskID) ?? resumingTask

                    // Compose and deliver task briefing directly to Brown
                    var briefingParts: [String] = []
                    briefingParts.append("## Task: \(resumingTask.title)\n\n\(resumingTask.description)")

                    if !resumingTask.updates.isEmpty {
                        let history = resumingTask.updates.map { "- \($0.message)" }.joined(separator: "\n")
                        briefingParts.append("## Prior Progress\n\(history)")
                    }
                    if let brownContext = resumingTask.lastBrownContext {
                        briefingParts.append("## Last Working State\n\(brownContext)")
                    }

                    // Queue the synthetic ack BEFORE posting the briefing so it's
                    // guaranteed to be set before Brown's run loop processes the
                    // briefing message. Zero tokens, zero latency, no LLM call.
                    if let brownAgent = agents[brownID] {
                        await brownAgent.setSyntheticFirstToolCall("task_acknowledged")
                    }

                    await channel.post(ChannelMessage(
                        sender: .agent(.smith),
                        recipientID: brownID,
                        recipient: .agent(.brown),
                        content: briefingParts.joined(separator: "\n\n")
                    ))
                    brownSpawned = true
                } else {
                    brownSpawned = false
                }

                // Build Smith's initial instruction
                var smithParts: [String] = []

                let hasMemories = !(resumingTask.relevantMemories?.isEmpty ?? true)
                let hasPriorTasks = !(resumingTask.relevantPriorTasks?.isEmpty ?? true)
                if hasMemories || hasPriorTasks {
                    smithParts.append("""
                        ## Other information

                        The information below is NOT part of this task and does NOT reflect the user's intent for this task.
                        It is provided only because it MIGHT be a source of relevant context - but it also might be completely
                        useless and unrelated.

                        Use it with caution.

                        DO NOT ASSUME that any part of it might also apply to the current task. Rather, if there are things that
                        MIGHT apply, ASK the user for clarification right away.
                        """)
                    if let memories = resumingTask.relevantMemories, !memories.isEmpty {
                        let memoryLines = memories.map { "- \($0.content) (similarity: \(String(format: "%.2f", $0.similarity)))" }
                        smithParts.append("### Relevant memories:\n\(memoryLines.joined(separator: "\n"))")
                    }
                    if let priorTasks = resumingTask.relevantPriorTasks, !priorTasks.isEmpty {
                        let taskLines = priorTasks.map { task in
                            "- \(task.title): \(task.summary) (similarity: \(String(format: "%.2f", task.similarity)))"
                        }
                        smithParts.append("### Relevant prior task summaries:\n\(taskLines.joined(separator: "\n"))")
                    }
                }

                if brownSpawned {
                    smithParts.append("""
                        Brown is already working on task "\(resumingTask.title)" (ID: \(resumingTaskID.uuidString)). \
                        The task description and any prior progress have been delivered to Brown automatically. \
                        Do NOT call `run_task`, `create_task`, or `message_brown` — Brown is already briefed and working. \
                        Brown will signal progress via task_update / task_complete; you'll also get an automatic 10-minute Brown-activity digest. Do NOT poll.
                        """)
                } else {
                    smithParts.append("""
                        Failed to spawn Brown for task "\(resumingTask.title)" (ID: \(resumingTaskID.uuidString)). \
                        Check that a Brown LLM provider is configured. \
                        Send the user a message explaining that Brown could not be started.
                        """)
                }

                if let userMsg = lastUserMessage, !userMsg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    smithParts.append("The user's most recent message (before this restart): \"\(userMsg)\"")
                }

                initialInstruction = smithParts.joined(separator: "\n\n")
            } else {
                initialInstruction = """
                    The system restarted for task \(resumingTaskID.uuidString) but the task was not found in the store. \
                    Send the user a message explaining the issue.
                    """
            }
        } else {
            // Cold launch — gather all active tasks by status and surface everything to Smith.
            let awaitingReviewTasks = activeTasks.filter { $0.status == .awaitingReview }
            let interruptedTasks = activeTasks.filter { $0.status == .interrupted }
            let pendingTasks = activeTasks.filter { $0.status == .pending }
            let pausedTasks = activeTasks.filter { $0.status == .paused }
            let scheduledTasks = activeTasks.filter { $0.status == .scheduled }
            let recentFailed = Array(
                activeTasks
                    .filter { $0.status == .failed }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(5)
            )

            // Re-arm scheduled-task wakes that were lost when the previous run quit. For each
            // .scheduled task: if its `scheduledRunAt` is still in the future, register a wake
            // bound to it. If the time has elapsed during downtime, promote the task to .pending
            // and let it surface in the cold-launch instruction below — the user will see it as a
            // pending task and can run it (or auto-advance picks it up).
            let nowAtBoot = Date()
            for task in scheduledTasks {
                guard let fireAt = task.scheduledRunAt else { continue }
                if fireAt > nowAtBoot {
                    let imperative = TaskActionKind.run.imperativeText(for: task, extra: nil)
                    _ = await smithAgent.scheduleWake(
                        wakeAt: fireAt,
                        instructions: imperative,
                        taskID: task.id
                    )
                } else {
                    await taskStore.promoteScheduledToPending(id: task.id)
                }
            }

            // If autoRunInterruptedTasks is enabled and no awaitingReview task needs attention first,
            // auto-start the first interrupted task by spawning Brown and delivering the briefing.
            var autoResumedTask: AgentTask?
            if autoRunInterruptedTasks, awaitingReviewTasks.isEmpty, let task = interruptedTasks.first {
                if let brownID = await spawnBrown() {
                    await taskStore.updateStatus(id: task.id, status: .running)
                    await taskStore.assignAgent(taskID: task.id, agentID: brownID)

                    var briefingParts: [String] = []
                    briefingParts.append("## Task: \(task.title)\n\n\(task.description)")
                    if !task.updates.isEmpty {
                        let history = task.updates.map { "- \($0.message)" }.joined(separator: "\n")
                        briefingParts.append("## Prior Progress\n\(history)")
                    }
                    if let brownContext = task.lastBrownContext {
                        briefingParts.append("## Last Working State\n\(brownContext)")
                    }
                    if let brownAgent = agents[brownID] {
                        await brownAgent.setSyntheticFirstToolCall("task_acknowledged")
                    }
                    await channel.post(ChannelMessage(
                        sender: .agent(.smith),
                        recipientID: brownID,
                        recipient: .agent(.brown),
                        content: briefingParts.joined(separator: "\n\n")
                    ))
                    autoResumedTask = task
                }
            }

            // Build Smith's initial instruction with ALL task categories
            var parts: [String] = []

            if let resumed = autoResumedTask {
                parts.append("""
                    Brown has automatically resumed the interrupted task "\(resumed.title)" (ID: \(resumed.id.uuidString)). \
                    Do NOT call `message_brown` for this task — Brown is already briefed and working. \
                    Brown will signal progress via task_update / task_complete; you'll also get an automatic 10-minute Brown-activity digest. Do NOT poll.
                    """)
            }

            if !awaitingReviewTasks.isEmpty {
                let taskList = awaitingReviewTasks.map { task in
                    var entry = "- \(task.title) (id: \(task.id.uuidString))"
                    if let result = task.result {
                        entry += "\n  Result: \(result)"
                    }
                    if let commentary = task.commentary {
                        entry += "\n  Commentary: \(commentary)"
                    }
                    return entry
                }.joined(separator: "\n")
                parts.append("\(awaitingReviewTasks.count) task(s) are awaiting your review:\n\(taskList)\nReview each and call `review_work`.")
            }

            // Show interrupted tasks that were NOT auto-resumed
            let remainingInterrupted = interruptedTasks.filter { $0.id != autoResumedTask?.id }
            if !remainingInterrupted.isEmpty {
                let list = remainingInterrupted
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString)) — interrupted"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        if let lastUpdate = task.updates.last {
                            entry += "\n  Last update: \(lastUpdate.message)"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                parts.append("The following task(s) were interrupted and can be resumed with `run_task`:\n\(list)")
            }

            if !pendingTasks.isEmpty {
                let list = pendingTasks
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString))"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                parts.append("The following task(s) are pending and waiting to be started:\n\(list)")
            }

            if !pausedTasks.isEmpty {
                let list = pausedTasks
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString)) — paused"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        if let lastUpdate = task.updates.last {
                            entry += "\n  Last update: \(lastUpdate.message)"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                parts.append("The following task(s) are paused:\n\(list)")
            }

            if !scheduledTasks.isEmpty {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let list = scheduledTasks
                    .compactMap { task -> String? in
                        guard let fireAt = task.scheduledRunAt, fireAt > nowAtBoot else { return nil }
                        return "- \(task.title) (id: \(task.id.uuidString)) — scheduled to run at \(formatter.string(from: fireAt))"
                    }
                    .joined(separator: "\n")
                if !list.isEmpty {
                    parts.append("The following task(s) are scheduled to run at a specific time. The runtime will fire a timer at the appointed time and instruct you to call `run_task`. Do NOT call `run_task` on these early unless the user asks:\n\(list)")
                }
            }

            if !recentFailed.isEmpty {
                let list = recentFailed
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString))"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                parts.append("The following task(s) previously failed (most recent first):\n\(list)")
            }

            if parts.isEmpty {
                initialInstruction = """
                    No tasks are pending. Introduce yourself with "Hello <user's nickname>, how can I help?" - and nothing more.
                    """
            } else {
                initialInstruction = """
                    \(parts.joined(separator: "\n\n"))

                    Send the user a single private message (recipient_id: "user") summarizing the situation \
                    and asking how they would like to proceed. \
                    Then wait for the user to reply before taking action on any tasks. \
                    When the user asks you to continue or run a task, use `list_tasks` to get the full task \
                    details (including the description) before proceeding — do not ask the user for information \
                    that is already in the task.
                    """
            }
        }

        await smithAgent.start(initialInstruction: initialInstruction)
        onAgentStarted?(.smith, smithAgent.toolNames)

        await channel.post(ChannelMessage(
            sender: .system,
            content: "System online. Smith agent active."
        ))

        monitoringTimer = MonitoringTimer(
            interval: 60,
            channel: channel,
            taskStore: taskStore
        )
        await monitoringTimer?.start()
    }

    /// Sends a user message (with optional attachments) privately to Smith.
    public func sendUserMessage(_ text: String, attachments: [Attachment] = []) async {
        await powerManager?.activityOccurred()
        await channel.post(ChannelMessage(
            sender: .user,
            recipientID: smithID,
            recipient: .agent(.smith),
            content: text,
            attachments: attachments
        ))
    }

    /// Stops all agents and the monitoring timer.
    public func stopAll() async {
        await powerManager?.shutdown()
        powerManager = nil

        await monitoringTimer?.stop()
        monitoringTimer = nil

        // Save Brown's context summary to its task before stopping agents
        await saveBrownContextToTask()

        await withTaskGroup(of: Void.self) { group in
            for (_, agent) in agents {
                group.addTask { await agent.stop() }
            }
        }

        for (_, subIDs) in agentSubscriptions {
            for subID in subIDs {
                await channel.unsubscribe(subID)
            }
        }
        agentSubscriptions.removeAll()

        // Archive evaluation records before clearing evaluators.
        for (brownID, evaluator) in securityEvaluators {
            let records = await evaluator.evaluationHistory()
            if !records.isEmpty {
                archivedEvaluationRecords[brownID] = records
            }
        }

        agents.removeAll()
        agentRoles.removeAll()
        securityEvaluators.removeAll()
        currentBrownID = nil
        smith = nil
        smithID = nil
        currentSessionID = nil
        await channel.setCurrentSessionID(nil)

        await channel.post(ChannelMessage(
            sender: .system,
            content: "All agents stopped."
        ))
    }

    /// Emergency abort triggered by an agent. Stops everything; requires user interaction to restart.
    public func abort(reason: String, callerRole: AgentRole? = nil) async {
        guard !aborted else { return }
        aborted = true

        let callerName = callerRole?.displayName ?? "safety monitor"
        await channel.post(ChannelMessage(
            sender: .system,
            content: "ABORT triggered by \(callerName): \(reason). All agents stopped. User interaction required to restart."
        ))

        await stopAll()
        onAbort?("ABORT triggered by \(callerName): \(reason)")
    }

    /// Spawns a Brown+Jones pair. Terminates any existing Brown first (single Brown policy).
    public func spawnBrown() async -> UUID? {
        guard !aborted else { return nil }

        // Enforce single Brown — terminate existing one if present
        if let existingBrownID = currentBrownID {
            _ = await terminateAgent(id: existingBrownID)
        }

        guard let brownConfig = llmConfigs[.brown],
              let brownProvider = llmProviders[.brown] else {
            await channel.post(ChannelMessage(sender: .system, content: "No Brown provider configured — cannot spawn."))
            return nil
        }
        guard let jonesProvider = llmProviders[.jones] else {
            await channel.post(ChannelMessage(sender: .system, content: "No Jones provider configured — Brown requires a security evaluator."))
            return nil
        }

        let brownID = UUID()

        // Tool-execution tracker shared between Brown's tool context (writer) and the
        // SecurityEvaluator's Jones prompt (reader) so Jones can see whether an approved
        // tool call actually succeeded or failed. Without this shared instance, retries
        // after a tool error would be misread as duplicate operations and denied.
        let executionTracker = ToolExecutionTracker()

        // Create SecurityEvaluator with Jones's LLM config — replaces the Jones agent.
        let jonesConfig = llmConfigs[.jones]
        let evaluator = SecurityEvaluator(
            provider: jonesProvider,
            systemPrompt: JonesBehavior.systemPrompt,
            channel: channel,
            abort: { [weak self] reason, callerRole in
                guard let self else { return }
                await self.abort(reason: reason, callerRole: callerRole)
            },
            usageStore: usageStore,
            configuration: jonesConfig,
            providerType: providerAPITypes[.jones]?.rawValue ?? "",
            sessionID: currentSessionID,
            hasToolSucceeded: { [executionTracker] toolCallID in
                await executionTracker.hasSucceeded(toolCallID: toolCallID)
            },
            hasToolFailed: { [executionTracker] toolCallID in
                await executionTracker.hasFailed(toolCallID: toolCallID)
            }
        )
        securityEvaluators[brownID] = evaluator

        // Brown's message filter: drop security review messages and tool execution trace messages.
        // Brown already receives all security feedback directly as tool results — approved calls
        // return the tool output, denied calls return "Tool execution denied: <reason>".
        // Echoing these through the channel as [System] messages wastes tokens and adds noise.
        let brownMessageFilter: @Sendable (ChannelMessage) -> Bool = { message in
            // Drop all security disposition messages (SAFE/WARN/UNSAFE/ABORT).
            if message.metadata?["securityDisposition"] != nil { return false }
            // Drop tool_request and tool_output echo messages (posted for UI visibility only).
            if case .string(let kind) = message.metadata?["messageKind"],
               kind == "tool_request" || kind == "tool_output" { return false }
            return true
        }

        let filesRead = FileReadTracker()
        let brownContext = makeToolContext(
            agentID: brownID,
            role: .brown,
            filesReadInSession: filesRead,
            executionTracker: executionTracker
        )

        // Pre-flight `gh auth status` so Brown sees verified GitHub auth state in his tool list
        // from turn one. Capturing once at spawn is sufficient — auth doesn't change mid-task.
        // The snapshot lands inside `GhTool.toolDescription`; it is intentionally NOT posted to
        // the channel so it does not clutter the user-visible transcript.
        let ghAuthSnapshot = await GhAuthChecker.authStatus()

        let brownAgent = AgentActor(
            id: brownID,
            configuration: AgentConfiguration(
                role: .brown,
                llmConfig: brownConfig,
                providerAPIType: providerAPITypes[.brown] ?? .openAICompatible,
                systemPrompt: BrownBehavior.systemPrompt,
                toolNames: BrownBehavior.toolNames,
                requiresToolApproval: true,
                pollInterval: agentTuning[.brown]?.pollInterval ?? 25,
                messageDebounceInterval: agentTuning[.brown]?.messageDebounceInterval ?? 1,
                messageAcceptFilter: brownMessageFilter,
                maxToolCallsPerIteration: agentTuning[.brown]?.maxToolCalls ?? 100
            ),
            provider: brownProvider,
            tools: BrownBehavior.tools(ghAuthStatusSnapshot: ghAuthSnapshot),
            toolContext: brownContext
        )
        await brownAgent.setSecurityEvaluator(evaluator)
        await brownAgent.setUsageStore(usageStore)
        await brownAgent.setSessionID(currentSessionID)
        if let turnCallback = onTurnRecorded {
            await brownAgent.setOnTurnRecorded { turn in turnCallback(.brown, turn) }
        }
        if let contextCallback = onContextChanged {
            await brownAgent.setOnContextChanged { messages in contextCallback(.brown, messages) }
        }
        if let evalCallback = onEvaluationRecorded {
            await evaluator.setOnEvaluationRecorded(evalCallback)
        }

        agents[brownID] = brownAgent
        agentRoles[brownID] = .brown
        currentBrownID = brownID

        let brownSubID = await channel.subscribe { [weak brownAgent] message in
            guard let brownAgent else { return }
            Task { await brownAgent.receiveChannelMessage(message) }
        }
        agentSubscriptions[brownID] = [brownSubID]

        // Announce Jones is online (evaluator is ready) for UI consistency.
        await channel.post(ChannelMessage(
            sender: .agent(.jones),
            content: "Jones security evaluator online.",
            metadata: ["messageKind": .string("agent_online")]
        ))
        onAgentStarted?(.jones, JonesBehavior.toolNames)

        await brownAgent.start()
        onAgentStarted?(.brown, brownAgent.toolNames)

        return brownID
    }

    /// Terminates a specific agent. If it's a Brown, also cleans up its SecurityEvaluator.
    public func terminateAgent(id: UUID, callerID: UUID? = nil) async -> Bool {
        guard let agent = agents[id] else { return false }

        // Archive the agent's state before termination so the inspector can still display it.
        if let role = agentRoles[id] {
            await archiveAgent(agent, role: role)
        }

        // Archive the security evaluator's history before removing it.
        if let evaluator = securityEvaluators.removeValue(forKey: id) {
            let records = await evaluator.evaluationHistory()
            archivedEvaluationRecords[id] = records
        }

        await agent.stop()
        agents.removeValue(forKey: id)
        agentRoles.removeValue(forKey: id)
        await unsubscribeAgent(id: id)

        // Scrub the terminated agent's UUID from every task's assignee list so stale
        // Brown UUIDs don't accumulate across respawns. Without this, the periodic
        // status messages Smith sees ("assigned to N agents") grow monotonically and
        // misrepresent how many agents are actually live on a task.
        await taskStore.unassignAgentFromAllTasks(agentID: id)

        if currentBrownID == id {
            currentBrownID = nil
        }

        return true
    }

    /// Returns a snapshot of the conversation history for the active agent with the given role.
    public func contextSnapshot(for role: AgentRole) async -> [LLMMessage]? {
        guard let agentID = agentIDForRole(role), let agent = agents[agentID] else { return nil }
        return await agent.contextSnapshot()
    }

    /// Returns a snapshot of recent LLM turns for the active agent with the given role.
    public func turnsSnapshot(for role: AgentRole) async -> [LLMTurnRecord]? {
        guard let agentID = agentIDForRole(role), let agent = agents[agentID] else { return nil }
        return await agent.turnsSnapshot()
    }

    /// Returns the security evaluation history for the current (or most recent) Brown.
    public func evaluationHistory() async -> [EvaluationRecord] {
        // Try active evaluator first.
        if let brownID = currentBrownID, let evaluator = securityEvaluators[brownID] {
            return await evaluator.evaluationHistory()
        }
        // Fall back to archived records from the most recently terminated Brown.
        if let records = archivedEvaluationRecords.values.max(by: {
            ($0.last?.timestamp ?? .distantPast) < ($1.last?.timestamp ?? .distantPast)
        }) {
            return records
        }
        return []
    }

    /// Terminates all agents assigned to a task. Used when the user stops or pauses a task
    /// from the UI — the task status alone doesn't stop Brown's LLM loop.
    public func terminateTaskAgents(taskID: UUID) async {
        guard let task = await taskStore.task(id: taskID) else { return }
        for agentID in task.assigneeIDs {
            _ = await terminateAgent(id: agentID)
        }
    }

    /// Summarizes a completed or failed task and saves the embedding to the memory store.
    ///
    /// Runs as a fire-and-forget operation — errors are posted to the channel.
    public func summarizeAndEmbedTask(taskID: UUID) async {
        guard let task = await taskStore.task(id: taskID) else { return }
        guard task.status == .completed || (task.status == .failed && !task.updates.isEmpty) else { return }

        if let summarizer = taskSummarizer {
            await notifyProcessingStateChange(role: .summarizer, isProcessing: true)
            let summary = await summarizer.summarizeAndEmbed(task: task)
            await notifyProcessingStateChange(role: .summarizer, isProcessing: false)
            if let summary {
                await taskStore.setSummary(id: taskID, summary: summary)
            }
        }
    }

    /// Posts a private message from the user directly to the agent with the given role.
    public func sendDirectMessage(to role: AgentRole, text: String) async {
        guard let agentID = agentIDForRole(role) else { return }
        await channel.post(ChannelMessage(
            sender: .user,
            recipientID: agentID,
            recipient: .agent(role),
            content: text
        ))
    }

    /// Replaces the system prompt in the active agent's conversation history.
    public func updateSystemPrompt(for role: AgentRole, prompt: String) async {
        guard let agentID = agentIDForRole(role), let agent = agents[agentID] else { return }
        await agent.updateSystemPrompt(prompt)
    }

    /// Updates the idle poll interval for the active agent with the given role.
    public func updatePollInterval(for role: AgentRole, interval: TimeInterval) async {
        guard let agentID = agentIDForRole(role), let agent = agents[agentID] else { return }
        await agent.updatePollInterval(interval)
    }

    /// Updates the maximum tool calls per LLM response for the active agent with the given role.
    public func updateMaxToolCalls(for role: AgentRole, count: Int) async {
        guard let agentID = agentIDForRole(role), let agent = agents[agentID] else { return }
        await agent.updateMaxToolCalls(count)
    }

    /// All currently active agent IDs.
    public func activeAgentIDs() -> [UUID] {
        Array(agents.keys)
    }

    // MARK: - Agent Archive

    /// Snapshot of a terminated agent's state, preserved for inspector display.
    public struct AgentArchiveEntry: Sendable {
        public let role: AgentRole
        public let contextSnapshot: [LLMMessage]
        public let turnsSnapshot: [LLMTurnRecord]
        public let terminatedAt: Date
    }

    /// Returns the archived snapshot for a terminated agent role, if any.
    public func archivedSnapshot(for role: AgentRole) -> AgentArchiveEntry? {
        terminatedAgentArchive[role]
    }

    /// Snapshots the given agent's state into the archive before it is deallocated.
    private func archiveAgent(_ agent: AgentActor, role: AgentRole) async {
        let context = await agent.contextSnapshot()
        let turns = await agent.turnsSnapshot()
        terminatedAgentArchive[role] = AgentArchiveEntry(
            role: role,
            contextSnapshot: context,
            turnsSnapshot: turns,
            terminatedAt: Date()
        )
    }

    // MARK: - Private

    /// Removes channel subscriptions for a given agent.
    private func unsubscribeAgent(id: UUID) async {
        guard let subIDs = agentSubscriptions.removeValue(forKey: id) else { return }
        for subID in subIDs {
            await channel.unsubscribe(subID)
        }
    }

    private func makeToolContext(
        agentID: UUID,
        role: AgentRole,
        followUpScheduler: FollowUpScheduler? = nil,
        currentResumingTaskID: UUID? = nil,
        filesReadInSession: FileReadTracker? = nil,
        executionTracker: ToolExecutionTracker? = nil
    ) -> ToolContext {
        // Strong-capture the tracker so it survives beyond this stack frame. Callers that
        // also need to read tool-execution outcomes (e.g. SecurityEvaluator) must pass the
        // same instance via this parameter so writer (tool execute) and reader (Jones prompt)
        // share state. When unset, a fresh tracker is created for this agent only — that
        // agent's writes/reads stay consistent, but no one else can observe them.
        let tracker = executionTracker ?? ToolExecutionTracker()

        return ToolContext(
            agentID: agentID,
            agentRole: role,
            channel: channel,
            taskStore: taskStore,
            currentConfiguration: llmConfigs[role],
            currentProviderType: providerAPITypes[role]?.rawValue,
            spawnBrown: { [weak self] in
                guard let self else { return nil }
                return await self.spawnBrown()
            },
            terminateAgent: { [weak self] id, callerID in
                guard let self else { return false }
                return await self.terminateAgent(id: id, callerID: callerID)
            },
            abort: { [weak self] reason, callerRole in
                guard let self else { return }
                await self.abort(reason: reason, callerRole: callerRole)
            },
            agentRoleForID: { [weak self] id in
                guard let self else { return nil }
                return await self.roleForAgent(id: id)
            },
            agentIDForRole: { [weak self] role in
                guard let self else { return nil }
                return await self.agentIDForRole(role)
            },
            onSelfTerminate: { [weak self] in
                guard let self else { return }
                await self.handleAgentSelfTerminate(id: agentID)
            },
            onProcessingStateChange: { [weak self] isProcessing in
                guard let self else { return }
                Task { await self.notifyProcessingStateChange(role: role, isProcessing: isProcessing) }
            },
            onJonesProcessingStateChange: { [weak self] isProcessing in
                guard let self else { return }
                Task { await self.notifyProcessingStateChange(role: .jones, isProcessing: isProcessing) }
            },
            scheduleWake: { [followUpScheduler] wakeAt, instructions, taskID, replacesID, recurrence in
                guard let followUpScheduler else { return .error("Scheduler not available.") }
                return await followUpScheduler.scheduleWake(
                    wakeAt: wakeAt,
                    instructions: instructions,
                    taskID: taskID,
                    replacesID: replacesID,
                    recurrence: recurrence
                )
            },
            listScheduledWakes: { [followUpScheduler] in
                guard let followUpScheduler else { return [] }
                return await followUpScheduler.listScheduledWakes()
            },
            cancelScheduledWake: { [followUpScheduler] id in
                guard let followUpScheduler else { return false }
                return await followUpScheduler.cancelWake(id: id)
            },
            restartForNewTask: { [weak self] taskID in
                guard let self else { return }
                await self.restartForNewTask(taskID: taskID)
            },
            currentResumingTaskID: currentResumingTaskID,
            memoryStore: memoryStore,
            summarizeCompletedTask: { [weak self] taskID in
                guard let self else { return }
                await self.summarizeAndEmbedTask(taskID: taskID)
            },
            mergeMemoryContent: { [weak self] existing, new in
                guard let self else { return nil }
                return await self.taskSummarizer?.mergeMemoryTexts(existing: existing, new: new)
            },
            autoAdvanceEnabled: { [weak self] in await self?.autoAdvanceEnabled ?? false },
            recordFileRead: { path in
                filesReadInSession?.record(path)
            },
            hasFileBeenRead: { path in
                filesReadInSession?.contains(path) ?? false
            },
            setToolExecutionStatus: { [tracker] toolCallID, succeeded in
                await tracker.recordExecutionStatus(toolCallID: toolCallID, succeeded: succeeded)
            },
            hasToolSucceeded: { [tracker] toolCallID in
                await tracker.hasSucceeded(toolCallID: toolCallID)
            },
            hasToolFailed: { [tracker] toolCallID in
                await tracker.hasFailed(toolCallID: toolCallID)
            }
        )
    }

    private func notifyProcessingStateChange(role: AgentRole, isProcessing: Bool) async {
        onProcessingStateChange?(role, isProcessing)
        await powerManager?.activityOccurred()
    }

    /// Cleans up registry entries and channel subscriptions when an agent's run loop exits on its own.
    /// Guarded by agents[id] presence to be idempotent with terminateAgent().
    private func handleAgentSelfTerminate(id: UUID) async {
        guard let agent = agents[id] else { return }

        // Archive the agent's state before cleanup so the inspector can still display it.
        if let role = agentRoles[id] {
            await archiveAgent(agent, role: role)
        }

        // Archive security evaluator records before cleanup.
        if let evaluator = securityEvaluators.removeValue(forKey: id) {
            let records = await evaluator.evaluationHistory()
            archivedEvaluationRecords[id] = records
        }

        agents.removeValue(forKey: id)
        agentRoles.removeValue(forKey: id)
        await unsubscribeAgent(id: id)

        // Mark any running tasks assigned to this agent as failed — no agent is working on them anymore.
        // Trigger summarization for tasks that had progress (updates).
        let allTasks = await taskStore.allTasks()
        for task in allTasks where task.assigneeIDs.contains(id) && task.status == .running {
            await taskStore.updateStatus(id: task.id, status: .failed)
            if !task.updates.isEmpty {
                Task.detached { [weak self] in
                    guard let self else { return }
                    await self.summarizeAndEmbedTask(taskID: task.id)
                }
            }
        }

        // Mirror the explicit `terminateAgent` cleanup: scrub this agent's UUID from every
        // task's assignee list so stale UUIDs don't accumulate across self-terminations.
        // Without this, the periodic "assigned to N agents" status grows monotonically
        // every time an agent's run loop exits on its own.
        await taskStore.unassignAgentFromAllTasks(agentID: id)

        if currentBrownID == id {
            currentBrownID = nil
        }

        if smithID == id {
            smith = nil
            smithID = nil
        }
    }

    /// Extracts Brown's last few assistant messages and saves a compressed context summary
    /// to the task it was working on, enabling better resumability.
    private func saveBrownContextToTask() async {
        guard let brownID = currentBrownID, let brown = agents[brownID] else { return }
        let context = await brown.contextSnapshot()

        // Find the task Brown was working on
        let task = await taskStore.taskForAgent(agentID: brownID)
        guard let task else { return }

        // Extract the last few assistant messages as a summary
        let assistantMessages = context.compactMap { msg -> String? in
            guard msg.role == .assistant else { return nil }
            switch msg.content {
            case .text(let s) where !s.isEmpty: return s
            case .mixed(let s, let calls) where !s.isEmpty || !calls.isEmpty:
                let toolPart = calls.map { "[\($0.name)]" }.joined(separator: ", ")
                return [s, toolPart].filter { !$0.isEmpty }.joined(separator: " ")
            case .toolCalls(let calls):
                return calls.map { "[\($0.name)]" }.joined(separator: ", ")
            default: return nil
            }
        }
        let recentMessages = assistantMessages.suffix(5)
        guard !recentMessages.isEmpty else { return }

        let summary = recentMessages.joined(separator: "\n---\n")
        // Cap to prevent storing extremely long context
        let truncated = summary.count > 2000 ? String(summary.suffix(2000)) : summary
        await taskStore.setLastBrownContext(id: task.id, context: truncated)
    }

    /// Builds Smith's periodic Brown-activity digest from channel history since `since`.
    /// Returns nil when nothing meaningful has happened (so the digest wake is suppressed).
    ///
    /// Iteration is bounded to messages in `[since, now]` via the channel's binary-search
    /// `messages(since:)` lookup so this is cheap even when the channel holds the full
    /// 10K-message backlog. Jones denial breadcrumbs are detected via the structured
    /// `securityDisposition` metadata key (set by `SecurityEvaluator.postToChannel` on
    /// ABORT messages) rather than by substring-matching the rendered content.
    static func assembleBrownActivityDigest(channel: MessageChannel, since: Date) async -> String? {
        let recent = await channel.messages(since: since)
        guard !recent.isEmpty else { return nil }

        var taskUpdateCount = 0
        var toolCallCount = 0
        var toolBuckets: [String: Int] = [:]
        var lastUpdate: String?
        var lastUpdateAt: Date?
        var jonesDenials = 0
        var lastDenial: String?
        var msgFromBrownToSmith: [(Date, String)] = []

        for msg in recent {
            // Brown public/tool messages — count tool calls once per request (not also per output).
            if case .agent(let role) = msg.sender, role == .brown {
                if case .string("tool_request") = msg.metadata?["messageKind"] {
                    toolCallCount += 1
                    if case .string(let name) = msg.metadata?["tool"] {
                        toolBuckets[name, default: 0] += 1
                    }
                } else if msg.metadata?["tool"] != nil {
                    // tool_output — already accounted for via tool_request, skip.
                } else if case .string(let kind) = msg.metadata?["messageKind"] {
                    if kind == "task_update" {
                        taskUpdateCount += 1
                        lastUpdate = msg.content
                        lastUpdateAt = msg.timestamp
                    } else if kind == "task_complete" {
                        msgFromBrownToSmith.append((msg.timestamp, "task_complete: " + String(msg.content.prefix(120))))
                    }
                } else if msg.recipientID != nil {
                    // Private Brown→Smith messages (other than the structured kinds above).
                    msgFromBrownToSmith.append((msg.timestamp, String(msg.content.prefix(120))))
                }
            }
            // Jones denial breadcrumbs: structured metadata key set by
            // `AgentActor.postSecurityReviewToChannel` ("denied") and `SecurityEvaluator`
            // ("abort"). Substring-matching the content was unreliable — Smith log lines
            // often quote denial reasons and would have been counted as denials themselves.
            if case .string(let dispo) = msg.metadata?["securityDisposition"],
               dispo == "abort" || dispo == "denied" {
                jonesDenials += 1
                lastDenial = msg.content
            }
        }

        var lines: [String] = []
        lines.append("- Brown made \(toolCallCount) tool call(s) and sent \(taskUpdateCount) task_update(s).")
        if !toolBuckets.isEmpty {
            let topTools = toolBuckets.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: ", ")
            lines.append("- Top tools: \(topTools)")
        }
        if let lastUpdate, let lastUpdateAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let preview = lastUpdate.replacingOccurrences(of: "\n", with: " ")
            let trimmed = preview.count > 200 ? String(preview.prefix(200)) + "…" : preview
            lines.append("- Last task_update at \(formatter.string(from: lastUpdateAt)): \(trimmed)")
        } else {
            lines.append("- No task_update from Brown in this window — likely deep in tool work or stuck.")
        }
        if jonesDenials > 0 {
            lines.append("- Jones denied \(jonesDenials) call(s). Latest reason snippet: \((lastDenial ?? "").prefix(160))")
        }
        for (_, text) in msgFromBrownToSmith.prefix(3) {
            lines.append("- Brown→Smith: \(text)")
        }
        return lines.joined(separator: "\n")
    }
}
