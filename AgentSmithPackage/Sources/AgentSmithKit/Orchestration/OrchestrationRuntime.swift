import Foundation

/// Top-level runtime that owns all agents, the channel, and the task store.
public actor OrchestrationRuntime {
    public let channel: MessageChannel
    public let taskStore: TaskStore

    /// Fixed UUID representing the human user for private Smith→User messages.
    public static let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private var smith: AgentActor?
    private var smithID: UUID?
    private var agents: [UUID: AgentActor] = [:]

    /// Current Brown agent ID (only one active at a time).
    private var currentBrownID: UUID?
    /// Maps Brown agent IDs to their paired Jones agent IDs.
    private var brownToJones: [UUID: UUID] = [:]
    /// Maps agent IDs to their roles for access-control lookups.
    private var agentRoles: [UUID: AgentRole] = [:]

    private var llmConfigs: [AgentRole: LLMConfiguration]
    private var monitoringTimer: MonitoringTimer?
    /// Maps Brown agent IDs to their active ToolRequestGate so we can drain pending approvals on shutdown.
    private var toolRequestGates: [UUID: ToolRequestGate] = [:]
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

    public init(llmConfigs: [AgentRole: LLMConfiguration]) {
        self.channel = MessageChannel()
        self.taskStore = TaskStore()
        self.llmConfigs = llmConfigs
    }

    /// Updates the LLM configuration for a given role.
    public func updateConfig(for role: AgentRole, config: LLMConfiguration) {
        llmConfigs[role] = config
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

    /// Starts the Smith agent and the monitoring timer.
    public func start() async {
        guard smith == nil else { return }
        guard !aborted else { return }

        let smithConfig = llmConfigs[.smith] ?? .ollamaDefault
        let provider = makeProvider(config: smithConfig)

        let id = UUID()
        smithID = id
        let followUpScheduler = FollowUpScheduler()
        let context = makeToolContext(agentID: id, role: .smith, followUpScheduler: followUpScheduler)

        // Smith only wakes for: private messages (user/Brown/Jones→Smith), system termination notices.
        // Public Brown messages, tool_request/tool execution messages, and security review notices
        // are completely filtered out — they generate too much noise and don't need Smith's attention.
        let smithMessageFilter: @Sendable (ChannelMessage) -> Bool = { message in
            // Drop all public messages from Brown or Jones — Smith only cares about their private replies.
            if case .agent(let role) = message.sender, message.recipientID == nil,
               role == .brown || role == .jones {
                return false
            }
            // Drop tool_request messages (Brown's approval requests, already public Brown → caught above,
            // but guard here in case routing changes).
            if case .string(let kind) = message.metadata?["messageKind"], kind == "tool_request" {
                return false
            }
            // Drop tool execution trace messages.
            if message.metadata?["tool"] != nil {
                return false
            }
            // Drop security review status lines posted by the approval gate.
            if case .system = message.sender, message.content.hasPrefix("Security review:") {
                return false
            }
            return true
        }

        let smithAgent = AgentActor(
            id: id,
            configuration: AgentConfiguration(
                role: .smith,
                llmConfig: smithConfig,
                systemPrompt: SmithBehavior.systemPrompt,
                toolNames: SmithBehavior.toolNames,
                suppressesRawTextToChannel: true,
                pollInterval: 20,
                messageDebounceInterval: 5,
                messageAcceptFilter: smithMessageFilter
            ),
            provider: provider,
            tools: SmithBehavior.tools(),
            toolContext: context
        )
        await followUpScheduler.set(agent: smithAgent)

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
        if !stalledTasks.isEmpty {
            // Tasks were actively running when the system stopped — ask the user whether to resume.
            let taskList = stalledTasks
                .map { "- \($0.title) (id: \($0.id.uuidString))" }
                .joined(separator: "\n")
            initialInstruction = """
                Start by calling list_tasks to review all current tasks.
                \(stalledTasks.count) task(s) were in progress when the system last stopped and have been reset to pending:
                \(taskList)
                After reviewing, send the user a private message (recipient_id: "user") listing these tasks \
                and asking which, if any, they would like to resume.
                """
        } else {
            // No tasks in progress — surface any recent failures for the user to decide on.
            let recentFailed = Array(
                activeTasks
                    .filter { $0.status == .failed }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(5)
            )
            if !recentFailed.isEmpty {
                let taskList = recentFailed
                    .map { "- \($0.title) (id: \($0.id.uuidString))" }
                    .joined(separator: "\n")
                initialInstruction = """
                    Start by calling list_tasks to review all current tasks.
                    No tasks were in progress, but the following task(s) previously failed (most recent first):
                    \(taskList)
                    After reviewing, send the user a private message (recipient_id: "user") listing these \
                    failed tasks and asking if they would like to retry any of them.
                    """
            } else {
                initialInstruction = """
                    Start by calling list_tasks to review the current task state, \
                    then await instructions from the user.
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
        await monitoringTimer?.stop()
        monitoringTimer = nil

        // Drain all pending tool-approval continuations before stopping agents so no Task is
        // left suspended forever waiting for a Jones that is about to be torn down.
        for (_, gate) in toolRequestGates {
            await gate.drainAll(approved: false, message: "System shutting down")
        }
        toolRequestGates.removeAll()

        for (_, agent) in agents {
            await agent.stop()
        }

        for (_, subIDs) in agentSubscriptions {
            for subID in subIDs {
                await channel.unsubscribe(subID)
            }
        }
        agentSubscriptions.removeAll()

        agents.removeAll()
        agentRoles.removeAll()
        brownToJones.removeAll()
        currentBrownID = nil
        smith = nil
        smithID = nil

        await channel.post(ChannelMessage(
            sender: .system,
            content: "All agents stopped."
        ))
    }

    /// Emergency abort triggered by Jones. Stops everything; requires user interaction to restart.
    public func abort(reason: String) async {
        guard !aborted else { return }
        aborted = true

        await channel.post(ChannelMessage(
            sender: .system,
            content: "ABORT triggered by safety monitor: \(reason). All agents stopped. User interaction required to restart."
        ))

        await stopAll()
        onAbort?(reason)
    }

    /// Spawns a Brown+Jones pair. Terminates any existing Brown first (single Brown policy).
    public func spawnBrown() async -> UUID? {
        guard !aborted else { return nil }

        // Enforce single Brown — terminate existing one if present
        if let existingBrownID = currentBrownID {
            _ = await terminateAgent(id: existingBrownID)
        }

        let brownConfig = llmConfigs[.brown] ?? .ollamaDefault
        let jonesConfig = llmConfigs[.jones] ?? .ollamaDefault

        let brownID = UUID()
        let jonesID = UUID()

        let gate = ToolRequestGate()
        toolRequestGates[brownID] = gate

        let brownContext = makeToolContext(agentID: brownID, role: .brown)
        let brownAgent = AgentActor(
            id: brownID,
            configuration: AgentConfiguration(
                role: .brown,
                llmConfig: brownConfig,
                systemPrompt: BrownBehavior.systemPrompt,
                toolNames: BrownBehavior.toolNames,
                requiresToolApproval: true,
                pollInterval: 25
            ),
            provider: makeProvider(config: brownConfig),
            tools: BrownBehavior.tools(),
            toolContext: brownContext
        )
        await brownAgent.setToolRequestGate(gate)

        // Jones needs Smith's UUID in its system prompt so it can call terminate_agent correctly.
        // This should never be nil — spawnBrown is only reachable while Smith is running.
        let smithIDForJones: UUID
        if let id = smithID {
            smithIDForJones = id
        } else {
            assertionFailure("spawnBrown called without an active Smith — Jones will receive an incorrect Smith UUID")
            smithIDForJones = UUID()
        }

        let jonesContext = makeToolContext(agentID: jonesID, role: .jones)
        let jonesAgent = AgentActor(
            id: jonesID,
            configuration: AgentConfiguration(
                role: .jones,
                llmConfig: jonesConfig,
                systemPrompt: JonesBehavior.systemPrompt(brownID: brownID, smithID: smithIDForJones),
                toolNames: JonesBehavior.toolNames,
                messageFilter: .toolRequestsOnly,
                suppressesRawTextToChannel: true,
                pollInterval: 13
            ),
            provider: makeProvider(config: jonesConfig),
            tools: JonesBehavior.tools(gate: gate),
            toolContext: jonesContext
        )

        agents[brownID] = brownAgent
        agents[jonesID] = jonesAgent
        agentRoles[brownID] = .brown
        agentRoles[jonesID] = .jones
        brownToJones[brownID] = jonesID
        currentBrownID = brownID

        let brownSubID = await channel.subscribe { [weak brownAgent] message in
            guard let brownAgent else { return }
            Task { await brownAgent.receiveChannelMessage(message) }
        }
        let jonesSubID = await channel.subscribe { [weak jonesAgent] message in
            guard let jonesAgent else { return }
            Task { await jonesAgent.receiveChannelMessage(message) }
        }
        agentSubscriptions[brownID] = [brownSubID]
        agentSubscriptions[jonesID] = [jonesSubID]

        // Start both agents — they will auto-announce on the channel.
        await jonesAgent.start()
        onAgentStarted?(.jones, jonesAgent.toolNames)
        await brownAgent.start()
        onAgentStarted?(.brown, brownAgent.toolNames)

        return brownID
    }

    /// Terminates a specific agent. If it's a Brown, also stops its paired Jones.
    public func terminateAgent(id: UUID) async -> Bool {
        guard let agent = agents[id] else { return false }

        // Drain any pending approval requests before stopping so Brown's suspended tool
        // calls are unblocked rather than leaking as orphaned continuations.
        if let gate = toolRequestGates.removeValue(forKey: id) {
            await gate.drainAll(approved: false, message: "Agent terminated")
        }

        await agent.stop()
        agents.removeValue(forKey: id)
        agentRoles.removeValue(forKey: id)
        await unsubscribeAgent(id: id)

        if let jonesID = brownToJones[id] {
            if let jones = agents[jonesID] {
                await jones.stop()
                agents.removeValue(forKey: jonesID)
                agentRoles.removeValue(forKey: jonesID)
            }
            await unsubscribeAgent(id: jonesID)
            brownToJones.removeValue(forKey: id)
        }

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

    /// All currently active agent IDs.
    public func activeAgentIDs() -> [UUID] {
        Array(agents.keys)
    }

    // MARK: - Private

    /// Removes channel subscriptions for a given agent.
    private func unsubscribeAgent(id: UUID) async {
        guard let subIDs = agentSubscriptions.removeValue(forKey: id) else { return }
        for subID in subIDs {
            await channel.unsubscribe(subID)
        }
    }

    private func makeProvider(config: LLMConfiguration) -> any LLMProvider {
        switch config.providerType {
        case .anthropic:
            return AnthropicProvider(config: config)
        case .openAICompatible:
            return OpenAICompatibleProvider(config: config)
        case .ollama:
            return OllamaProvider(config: config)
        }
    }

    private func makeToolContext(
        agentID: UUID,
        role: AgentRole,
        followUpScheduler: FollowUpScheduler? = nil
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
            terminateAgent: { [weak self] id in
                guard let self else { return false }
                return await self.terminateAgent(id: id)
            },
            abort: { [weak self] reason in
                guard let self else { return }
                await self.abort(reason: reason)
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
            scheduleFollowUp: { [followUpScheduler] delay in
                await followUpScheduler?.schedule(after: delay)
            }
        )
    }

    private func notifyProcessingStateChange(role: AgentRole, isProcessing: Bool) {
        onProcessingStateChange?(role, isProcessing)
    }

    /// Cleans up registry entries and channel subscriptions when an agent's run loop exits on its own.
    /// Guarded by agents[id] presence to be idempotent with terminateAgent().
    private func handleAgentSelfTerminate(id: UUID) async {
        guard agents[id] != nil else { return }

        // Drain any pending approval requests so Brown's suspended continuations are not leaked.
        if let gate = toolRequestGates.removeValue(forKey: id) {
            await gate.drainAll(approved: false, message: "Agent self-terminated")
        }

        agents.removeValue(forKey: id)
        agentRoles.removeValue(forKey: id)
        await unsubscribeAgent(id: id)

        // If this was a Brown, also stop its paired Jones.
        if let jonesID = brownToJones[id] {
            if let jones = agents[jonesID] {
                await jones.stop()
                agents.removeValue(forKey: jonesID)
                agentRoles.removeValue(forKey: jonesID)
            }
            await unsubscribeAgent(id: jonesID)
            brownToJones.removeValue(forKey: id)
        }

        if currentBrownID == id {
            currentBrownID = nil
        }

        if smithID == id {
            smith = nil
            smithID = nil
        }
    }

    private func defaultConfig() -> LLMConfiguration {
        .ollamaDefault
    }
}
