import Foundation

/// Top-level runtime that owns all agents, the channel, and the task store.
public actor OrchestrationRuntime {
    public let channel: MessageChannel
    public let taskStore: TaskStore

    private var smith: AgentActor?
    private var agents: [UUID: AgentActor] = [:]

    /// Current Brown agent ID (only one active at a time).
    private var currentBrownID: UUID?
    /// Maps Brown agent IDs to their paired Jones agent IDs.
    private var brownToJones: [UUID: UUID] = [:]

    private var llmConfigs: [AgentRole: LLMConfiguration]
    private var monitoringTimer: MonitoringTimer?
    /// Maps each agent ID to its channel subscription IDs for proper cleanup.
    private var agentSubscriptions: [UUID: [UUID]] = [:]

    /// Set by Jones abort — prevents restart until user clears it.
    private var aborted = false
    /// Callback to notify the app layer when abort is triggered.
    private var onAbort: (@Sendable (String) -> Void)?

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

    /// Whether the system has been aborted by Jones.
    public var isAborted: Bool { aborted }

    /// Clears the abort state so the system can be restarted.
    public func resetAbort() {
        aborted = false
    }

    /// Starts the Smith agent and the monitoring timer.
    public func start() async {
        guard smith == nil else { return }
        guard !aborted else { return }

        let smithConfig = llmConfigs[.smith] ?? .ollamaDefault
        let provider = makeProvider(config: smithConfig)

        let smithID = UUID()
        let context = makeToolContext(agentID: smithID, role: .smith)

        let smithAgent = AgentActor(
            id: smithID,
            configuration: AgentConfiguration(
                role: .smith,
                llmConfig: smithConfig,
                systemPrompt: SmithBehavior.systemPrompt,
                toolNames: SmithBehavior.toolNames
            ),
            provider: provider,
            tools: SmithBehavior.tools(),
            toolContext: context
        )

        smith = smithAgent
        agents[smithID] = smithAgent

        let subID = await channel.subscribe { [weak smithAgent] message in
            guard let smithAgent else { return }
            Task { await smithAgent.receiveChannelMessage(message) }
        }
        agentSubscriptions[smithID] = [subID]

        // Reset stalled tasks from prior sessions — no Brown is running them anymore
        let allTasks = await taskStore.allTasks()
        let stalledTasks = allTasks.filter { $0.status == .running }
        for task in stalledTasks {
            await taskStore.updateStatus(id: task.id, status: .pending)
        }

        let incompleteTasks = allTasks.filter { $0.status == .pending || $0.status == .running }
        let initialInstruction: String? = if !incompleteTasks.isEmpty {
            "System restarted. You have \(incompleteTasks.count) incomplete task(s) from a prior session (\(stalledTasks.count) were reset from running to pending). Use list_tasks to review them and decide how to proceed."
        } else {
            nil
        }

        await smithAgent.start(initialInstruction: initialInstruction)

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

    /// Sends a user message (with optional attachments) to the channel.
    public func sendUserMessage(_ text: String, attachments: [Attachment] = []) async {
        await channel.post(ChannelMessage(
            sender: .user,
            content: text,
            attachments: attachments
        ))
    }

    /// Stops all agents and the monitoring timer.
    public func stopAll() async {
        await monitoringTimer?.stop()
        monitoringTimer = nil

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
        brownToJones.removeAll()
        currentBrownID = nil
        smith = nil

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
            content: "ABORT triggered by Jones: \(reason). All agents stopped. User interaction required to restart."
        ))

        await stopAll()
        onAbort?(reason)
    }

    /// Spawns a Brown+Jones pair. Terminates any existing Brown first (single Brown policy).
    public func spawnBrown(taskID: String, instructions: String) async -> UUID? {
        guard !aborted else { return nil }

        // Enforce single Brown — terminate existing one if present
        if let existingBrownID = currentBrownID {
            _ = await terminateAgent(id: existingBrownID)
        }

        let brownConfig = llmConfigs[.brown] ?? .ollamaDefault
        let jonesConfig = llmConfigs[.jones] ?? .ollamaDefault

        let brownID = UUID()
        let jonesID = UUID()

        let brownContext = makeToolContext(agentID: brownID, role: .brown)
        let brownAgent = AgentActor(
            id: brownID,
            configuration: AgentConfiguration(
                role: .brown,
                llmConfig: brownConfig,
                systemPrompt: BrownBehavior.systemPrompt,
                toolNames: BrownBehavior.toolNames
            ),
            provider: makeProvider(config: brownConfig),
            tools: BrownBehavior.tools(),
            toolContext: brownContext
        )

        let jonesContext = makeToolContext(agentID: jonesID, role: .jones)
        let jonesAgent = AgentActor(
            id: jonesID,
            configuration: AgentConfiguration(
                role: .jones,
                llmConfig: jonesConfig,
                systemPrompt: JonesBehavior.systemPrompt,
                toolNames: JonesBehavior.toolNames
            ),
            provider: makeProvider(config: jonesConfig),
            tools: JonesBehavior.tools(),
            toolContext: jonesContext
        )

        agents[brownID] = brownAgent
        agents[jonesID] = jonesAgent
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

        let taskInstruction = "Task ID: \(taskID)\nInstructions: \(instructions)"
        await jonesAgent.start(
            initialInstruction: "Monitor the following task execution for safety.\n\(taskInstruction)"
        )
        await brownAgent.start(initialInstruction: taskInstruction)

        await channel.post(ChannelMessage(
            sender: .system,
            content: "Brown agent \(brownID) spawned with Jones monitor \(jonesID)."
        ))

        return brownID
    }

    /// Terminates a specific agent. If it's a Brown, also stops its paired Jones.
    public func terminateAgent(id: UUID) async -> Bool {
        guard let agent = agents[id] else { return false }

        await agent.stop()
        agents.removeValue(forKey: id)
        await unsubscribeAgent(id: id)

        if let jonesID = brownToJones[id] {
            if let jones = agents[jonesID] {
                await jones.stop()
                agents.removeValue(forKey: jonesID)
            }
            await unsubscribeAgent(id: jonesID)
            brownToJones.removeValue(forKey: id)
        }

        if currentBrownID == id {
            currentBrownID = nil
        }

        return true
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
        }
    }

    private func makeToolContext(agentID: UUID, role: AgentRole) -> ToolContext {
        ToolContext(
            agentID: agentID,
            agentRole: role,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { [weak self] taskID, instructions in
                guard let self else { return nil }
                return await self.spawnBrown(taskID: taskID, instructions: instructions)
            },
            terminateAgent: { [weak self] id in
                guard let self else { return false }
                return await self.terminateAgent(id: id)
            },
            abort: { [weak self] reason in
                guard let self else { return }
                await self.abort(reason: reason)
            }
        )
    }

    private func defaultConfig() -> LLMConfiguration {
        .ollamaDefault
    }
}
