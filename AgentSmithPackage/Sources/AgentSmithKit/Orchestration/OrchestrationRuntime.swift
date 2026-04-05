import Foundation

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
    private let autoAdvanceEnabled: Bool
    /// Persistent token usage tracking across all agents.
    public let usageStore: UsageStore
    private var monitoringTimer: MonitoringTimer?
    private var powerManager: PowerAssertionManager?
    /// Maps each agent ID to its channel subscription IDs for proper cleanup.
    private var agentSubscriptions: [UUID: [UUID]] = [:]

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

    public init(
        providers: [AgentRole: any LLMProvider],
        configurations: [AgentRole: ModelConfiguration],
        providerAPITypes: [AgentRole: ProviderAPIType] = [:],
        agentTuning: [AgentRole: AgentTuningConfig] = [:],
        embeddingService: EmbeddingService,
        usageStore: UsageStore,
        autoAdvanceEnabled: Bool = true
    ) {
        self.channel = MessageChannel()
        self.taskStore = TaskStore()
        self.memoryStore = MemoryStore(embeddingService: embeddingService)
        self.llmProviders = providers
        self.llmConfigs = configurations
        self.providerAPITypes = providerAPITypes
        self.agentTuning = agentTuning
        self.autoAdvanceEnabled = autoAdvanceEnabled
        self.usageStore = usageStore
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
            await self.stopAll()
            await self.start(resumingTaskID: taskID, lastUserMessage: lastUserMessage)
        }
    }

    /// Returns the content of the most recent user message from the channel, if any.
    private func captureLastUserMessage() async -> String? {
        let messages = await channel.allMessages()
        return messages.last(where: { message in
            if case .user = message.sender { return true }
            return false
        })?.content
    }

    /// Starts the Smith agent and the monitoring timer.
    /// - Parameter resumingTaskID: When set, skips the "ask user" preamble and immediately
    ///   instructs Smith to spawn Brown and begin work on this task.
    /// - Parameter lastUserMessage: The most recent user message captured before a restart,
    ///   included in the initial instruction so new Smith doesn't lose user context.
    public func start(resumingTaskID: UUID? = nil, lastUserMessage: String? = nil) async {
        guard smith == nil else { return }
        guard !aborted else { return }

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
                maxOutputTokens: summarizerConfig.maxTokens
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
            // agent lifecycle events (errors, termination) and rate-limit notices.
            // Drop startup/shutdown notices, monitoring summaries, approval statuses, etc.
            if case .system = message.sender {
                let c = message.content
                guard c.hasPrefix("Agent ") || c.hasPrefix("Rate limit:") else { return false }
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
        if let turnCallback = onTurnRecorded {
            await smithAgent.setOnTurnRecorded { turn in turnCallback(.smith, turn) }
        }
        if let contextCallback = onContextChanged {
            await smithAgent.setOnContextChanged { messages in contextCallback(.smith, messages) }
        }

        smith = smithAgent
        agents[id] = smithAgent
        agentRoles[id] = .smith

        let subID = await channel.subscribe { [weak smithAgent] message in
            guard let smithAgent else { return }
            Task { await smithAgent.receiveChannelMessage(message) }
        }
        agentSubscriptions[id] = [subID]

        // Reset stalled tasks from prior sessions — no Brown is running them anymore
        let allTasks = await taskStore.allTasks()
        let activeTasks = allTasks.filter { $0.disposition == .active }
        let stalledTasks = activeTasks.filter { $0.status == .running }
        for task in stalledTasks {
            await taskStore.updateStatus(id: task.id, status: .pending)
        }

        let initialInstruction: String

        // Fast path: restarting for a specific task — skip the "ask user" preamble
        // and instruct Smith to spawn Brown and begin work immediately.
        if let resumingTaskID {
            if let resumingTask = await taskStore.task(id: resumingTaskID) {
                var parts: [String] = []

                // Semantic context first — so Smith sees known facts before the action instructions.
                if let memories = resumingTask.relevantMemories, !memories.isEmpty {
                    let memoryLines = memories.map { "- \($0.content) (similarity: \(String(format: "%.2f", $0.similarity)))" }
                    parts.append("Relevant memories:\n\(memoryLines.joined(separator: "\n"))")
                }
                if let priorTasks = resumingTask.relevantPriorTasks, !priorTasks.isEmpty {
                    let taskLines = priorTasks.map { task in
                        "- \(task.title): \(task.summary) (similarity: \(String(format: "%.2f", task.similarity))) — full details: `get_task_details(task_id: \"\(task.taskID.uuidString)\")`"
                    }
                    parts.append("Relevant prior task summaries:\n\(taskLines.joined(separator: "\n"))")
                }

                parts.append("""
                    A new task has been created: "\(resumingTask.title)"

                    \(resumingTask.description)

                    Spawn Brown and begin work on this task immediately (task ID: \(resumingTaskID.uuidString)). \
                    Do not ask the user for confirmation — they just requested this task. \
                    Do NOT call `run_task` or `create_task` — the system has already restarted for this task. \
                    Call `spawn_brown` directly and give Brown the task instructions via `message_brown`. \
                    If relevant memories or prior task summaries are provided above, use those facts directly \
                    in your instructions to Brown — do not ask Brown to re-discover or re-verify them.
                    """)

                // Include prior progress context for resumed tasks
                if !resumingTask.updates.isEmpty {
                    let history = resumingTask.updates.map { "- \($0.message)" }.joined(separator: "\n")
                    parts.append("Prior progress updates from a previous attempt:\n\(history)\n\nPass this context to Brown so it can resume where the previous agent left off.")
                }
                if let brownContext = resumingTask.lastBrownContext {
                    parts.append("Last known Brown working state:\n\(brownContext)\n\nInclude this context when instructing Brown.")
                }
                if let userMsg = lastUserMessage, !userMsg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append("The user's most recent message (before this restart):\n\"\(userMsg)\"\n\nThis is authoritative — honor any permissions, scope changes, or instructions the user gave. Pass relevant parts to Brown.")
                }

                initialInstruction = parts.joined(separator: "\n\n")
            } else {
                initialInstruction = """
                    The system restarted for task \(resumingTaskID.uuidString) but the task was not found in the store. \
                    Send the user a message explaining the issue.
                    """
            }
        } else {

        // Gather awaitingReview tasks — these survive restart and need Smith's attention
        let awaitingReviewTasks = activeTasks.filter { $0.status == .awaitingReview }

        if !stalledTasks.isEmpty || !awaitingReviewTasks.isEmpty {
            var parts: [String] = []

            if !stalledTasks.isEmpty {
                let taskList = stalledTasks
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString))"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        if !task.updates.isEmpty {
                            let history = task.updates.map { "    - \($0.message)" }.joined(separator: "\n")
                            entry += "\n  Prior progress:\n\(history)"
                        }
                        if let brownContext = task.lastBrownContext {
                            entry += "\n  Last Brown state: \(String(brownContext.prefix(500)))"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                parts.append("\(stalledTasks.count) task(s) were in progress when the system last stopped and have been reset to pending:\n\(taskList)")
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

            initialInstruction = """
                \(parts.joined(separator: "\n\n"))
                Send the user a single private message (recipient_id: "user") summarizing the situation \
                and asking how they would like to proceed. \
                Then wait for the user to reply before taking action on any tasks. \
                When the user asks you to continue or run a task, use `list_tasks` to get the full task \
                details (including the description) before proceeding — do not ask the user for information \
                that is already in the task.
                """
        } else {
            // No tasks were running — surface any pending, paused, or recently failed tasks.
            let pendingTasks = activeTasks.filter { $0.status == .pending }
            let pausedTasks = activeTasks.filter { $0.status == .paused }
            let recentFailed = Array(
                activeTasks
                    .filter { $0.status == .failed }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(5)
            )

            if pendingTasks.isEmpty && pausedTasks.isEmpty && recentFailed.isEmpty {
                initialInstruction = """
                    No tasks are pending. Introduce yourself with "Hello <user's nickname>, how can I help?" - and nothing more.
                    """
            } else {
                var parts: [String] = []
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
                initialInstruction = """
                    \(parts.joined(separator: "\n\n"))
                    Send the user a single private message (recipient_id: "user") listing these tasks \
                    and asking what they would like to do. \
                    Then wait for the user to reply before taking action on any tasks. \
                    When the user asks you to continue or run a task, use `list_tasks` to get the full task \
                    details (including the description) before proceeding — do not ask the user for information \
                    that is already in the task.
                    """
            }
        }
        } // end else (no resumingTaskID)

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

        for (_, agent) in agents {
            await agent.stop()
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
            modelID: jonesConfig?.model ?? "",
            providerType: providerAPITypes[.jones]?.rawValue ?? "",
            configurationID: jonesConfig?.id
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
        let brownContext = makeToolContext(agentID: brownID, role: .brown, filesReadInSession: filesRead)
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
            tools: BrownBehavior.tools(),
            toolContext: brownContext
        )
        await brownAgent.setSecurityEvaluator(evaluator)
        await brownAgent.setUsageStore(usageStore)
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
        filesReadInSession: FileReadTracker? = nil
    ) -> ToolContext {
        ToolContext(
            agentID: agentID,
            agentRole: role,
            channel: channel,
            taskStore: taskStore,
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
            scheduleFollowUp: { [followUpScheduler] delay in
                await followUpScheduler?.schedule(after: delay)
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
            autoAdvanceEnabled: autoAdvanceEnabled,
            recordFileRead: { path in
                filesReadInSession?.record(path)
            },
            hasFileBeenRead: { path in
                filesReadInSession?.contains(path) ?? false
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

}
