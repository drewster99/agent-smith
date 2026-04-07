import Foundation
import os

/// Core agent actor: owns an LLM session, subscribes to the channel,
/// runs an async loop of receive -> LLM -> act -> report.
public actor AgentActor {
    public let id: UUID
    public let configuration: AgentConfiguration
    private let provider: any LLMProvider
    private let tools: [any AgentTool]
    private let toolContext: ToolContext

    private var conversationHistory: [LLMMessage] = []
    private var isRunning = false
    private var runTask: Task<Void, Never>?

    /// Direct security evaluator for tool approval (replaces Jones agent + ToolRequestGate).
    private var securityEvaluator: SecurityEvaluator?
    /// Token usage store for persistent analytics. Set via `setUsageStore(_:)`.
    private var usageStore: UsageStore?
    /// Captured before context pruning, emitted on the next UsageRecord.
    private var pendingPreResetTokens: Int?

    /// How long the idle loop waits between checks. Mutable so the user can adjust at runtime.
    private var pollInterval: TimeInterval

    /// Messages from the channel that arrived while waiting for the LLM.
    private var pendingChannelMessages: [ChannelMessage] = []

    /// Whether the agent has unprocessed input that requires an LLM call.
    /// Prevents re-querying the LLM with identical context after a text-only response.
    private var hasUnprocessedInput = false

    /// Timestamp of the most recently received channel message. Used for debounce.
    private var lastChannelMessageAt: Date?
    /// True only when the agent was idle and new channel messages arrived, triggering
    /// the debounce window. Cleared once we commit to an LLM call. Stays false during
    /// an active tool loop so tool results are processed without unnecessary delay.
    private var debouncingForMessages = false
    /// When non-nil, the agent wakes at this time even without new messages.
    private var scheduledWakeAt: Date?
    /// The currently sleeping idle task. Cancelling it wakes the agent early.
    private var idleSleepTask: Task<Void, Never>?

    /// Seconds of channel silence required before processing new messages.
    private let messageDebounceInterval: TimeInterval

    /// Timestamp of the most recent direct message from the user to this agent.
    /// Used to gate availability of the `reply_to_user` tool.
    private var lastDirectUserMessageAt: Date?

    /// Tracks consecutive LLM errors for exponential backoff.
    private var consecutiveErrors = 0
    private static let maxConsecutiveErrors = 50
    private static let maxBackoffSeconds: Double = 180

    /// Tracks consecutive context overflow errors (separate from general errors).
    /// Context overflows trigger aggressive pruning instead of backoff.
    private var consecutiveContextOverflows = 0
    private static let maxContextOverflowRetries = 3

    /// Tracks consecutive LLM responses that contain only text (no tool calls).
    /// When this exceeds the role-specific threshold, the agent is likely
    /// degenerate (e.g. repetition loop) and should be terminated.
    /// Brown (tool-heavy) triggers at 6; Smith (conversational) at 30.
    private var consecutiveTextOnlyResponses = 0

    /// Tracks consecutive identical tool calls (same name + same normalized arguments).
    /// Catches degenerate loops where the LLM repeatedly calls the same tool with the same
    /// arguments (e.g. task_update spam). Any different tool call or text-only response resets.
    /// Threshold of 4 is safely above the WARN retry case (max 2 identical calls).
    private var lastToolCallSignature: String?
    private var consecutiveIdenticalToolCalls = 0
    private static let maxConsecutiveIdenticalToolCalls = 4

    private var maxToolCallsPerIteration: Int
    /// Maximum concurrent Jones security evaluations to prevent overwhelming the LLM backend.
    private static let maxConcurrentEvaluations = 5

    /// Worst-case character overhead for tool definitions and per-turn suffixes
    /// that are sent with each API call but not stored in conversationHistory.
    private let apiOverheadChars: Int

    /// When true, the agent has called `task_complete` and is waiting for Smith's review.
    /// While set, `drainPendingMessages` will not re-wake the agent unless a private message
    /// addressed to it arrives (indicating Smith sent revision feedback).
    private var awaitingTaskReview = false

    /// Messages held back from the current drain to be delivered on a separate turn.
    /// Used to ensure task_complete messages get their own focused LLM turn.
    private var deferredMessages: [ChannelMessage] = []

    /// Per-turn LLM call log for per-turn inspection.
    private var llmTurns: [LLMTurnRecord] = []
    /// Message count at the time of the previous LLM call — used to compute inputDelta.
    private var lastTurnMessageCount: Int = 0

    /// Maximum number of turn records kept per agent. Oldest are dropped when exceeded.
    private static let maxTurnRecords = 100

    /// Only the most recent N turns retain their full contextSnapshot; older turns
    /// have the snapshot stripped to avoid O(n^2) memory growth across long sessions.
    private static let recentSnapshotWindow = 10

    /// Fires after each LLM turn is recorded, pushing the turn to the UI layer.
    private var onTurnRecorded: (@Sendable (LLMTurnRecord) -> Void)?

    /// Fires when the conversation history changes, pushing a live snapshot to the UI layer.
    private var onContextChanged: (@Sendable ([LLMMessage]) -> Void)?

    public init(
        id: UUID = UUID(),
        configuration: AgentConfiguration,
        provider: any LLMProvider,
        tools: [any AgentTool],
        toolContext: ToolContext
    ) {
        self.id = id
        self.configuration = configuration
        self.provider = provider
        self.tools = tools
        self.toolContext = toolContext
        self.pollInterval = configuration.pollInterval
        self.messageDebounceInterval = configuration.messageDebounceInterval
        self.maxToolCallsPerIteration = configuration.maxToolCallsPerIteration

        // Worst-case overhead: all tool definitions sent with each API call.
        let toolChars = tools.reduce(0) {
            $0 + $1.definition(for: configuration.role).estimatedCharacterCount
        }
        self.apiOverheadChars = toolChars

        conversationHistory.append(LLMMessage(
            role: .system,
            text: configuration.systemPrompt
        ))
    }

    /// Injects the security evaluator used for Brown's tool approval flow.
    public func setSecurityEvaluator(_ evaluator: SecurityEvaluator) {
        securityEvaluator = evaluator
    }

    /// Injects the usage store for persistent token analytics.
    public func setUsageStore(_ store: UsageStore) {
        usageStore = store
    }

    /// Registers a callback fired after each LLM turn is recorded.
    public func setOnTurnRecorded(_ handler: @escaping @Sendable (LLMTurnRecord) -> Void) {
        onTurnRecorded = handler
    }

    /// Registers a callback fired when the conversation history changes materially.
    public func setOnContextChanged(_ handler: @escaping @Sendable ([LLMMessage]) -> Void) {
        onContextChanged = handler
    }

    /// Returns a snapshot of the agent's full conversation history for inspection.
    public func contextSnapshot() -> [LLMMessage] {
        conversationHistory
    }

    /// Returns a snapshot of recent LLM turns for per-turn inspection.
    public func turnsSnapshot() -> [LLMTurnRecord] {
        llmTurns
    }

    /// Replaces the system prompt in the agent's conversation history.
    public func updateSystemPrompt(_ prompt: String) {
        guard !conversationHistory.isEmpty else { return }
        conversationHistory[0] = LLMMessage(role: .system, text: prompt)
        pushLiveContext()
    }

    /// Updates the idle poll interval for this agent.
    public func updatePollInterval(_ interval: TimeInterval) {
        pollInterval = interval
    }

    /// Updates the maximum number of tool calls executed per LLM response.
    public func updateMaxToolCalls(_ count: Int) {
        maxToolCallsPerIteration = count
    }

    /// Schedules a follow-up wake after the given delay, replacing any existing scheduled wake.
    public func scheduleFollowUp(after delay: TimeInterval) {
        scheduledWakeAt = Date().addingTimeInterval(delay)
        interruptIdleSleep()
    }

    /// Starts the agent's run loop.
    public func start(initialInstruction: String? = nil) {
        guard !isRunning else { return }
        isRunning = true

        if let instruction = initialInstruction {
            conversationHistory.append(LLMMessage(role: .user, text: instruction))
            hasUnprocessedInput = true
            pushLiveContext()
        }

        let role = configuration.role
        let channel = toolContext.channel
        let agentID = id
        runTask = Task { [weak self] in
            // Announce on the public channel so all agents and the UI know we're alive.
            await channel.post(ChannelMessage(
                sender: .agent(role),
                content: "\(role.displayName) agent \(agentID) is online.",
                metadata: ["messageKind": .string("agent_online")]
            ))

            guard let self else { return }
            await self.runLoop()
        }
    }

    /// Stops the agent.
    public func stop() {
        isRunning = false
        runTask?.cancel()
        runTask = nil
    }

    /// Injects a channel message into the agent's pending queue.
    ///
    /// Delivery rules:
    /// - Private messages (recipientID != nil) are only delivered to the named recipient.
    /// - Public messages are delivered to everyone except the sender's own role.
    /// - System messages are always delivered.
    public func receiveChannelMessage(_ message: ChannelMessage) {
        guard isRunning else { return }

        if let recipientID = message.recipientID {
            // Private message — only the intended recipient receives it.
            guard recipientID == id else { return }
        } else {
            // Public message — ignore our own role to avoid echo loops.
            if case .agent(let role) = message.sender, role == configuration.role {
                return
            }
        }

        // Drop UI-only notification messages that no agent needs to process.
        if case .string(let kind) = message.metadata?["messageKind"] {
            switch kind {
            case "task_created", "memory_saved", "memory_searched":
                return
            default:
                break
            }
        }

        // Drop error messages — they are for the UI only. Feeding them back into
        // agent conversation history wastes tokens and creates a death spiral when
        // the error is a context overflow (each retry adds the error text, growing
        // the context further).
        if case .bool(true) = message.metadata?["isError"] {
            return
        }

        // Optional per-agent content filter — drops messages that shouldn't trigger a wake.
        if let filter = configuration.messageAcceptFilter, !filter(message) { return }

        // Track when the user sends a direct message to this agent (for reply_to_user availability)
        if case .user = message.sender, message.recipientID == id {
            lastDirectUserMessageAt = Date()
        }

        pendingChannelMessages.append(message)
        lastChannelMessageAt = Date()
        // Only start debouncing if the agent was idle — during an active tool loop
        // we want tool results processed immediately without the debounce delay.
        if !hasUnprocessedInput {
            debouncingForMessages = true
        }
        interruptIdleSleep()
    }

    /// Whether the agent is currently running.
    public var running: Bool {
        isRunning
    }

    /// The names of tools available to this agent. Nonisolated because `configuration` is a let.
    public nonisolated var toolNames: [String] {
        configuration.toolNames
    }

    // MARK: - Private

    private func runLoop() async {
        while isRunning, !Task.isCancelled {
            // Re-inject deferred messages (e.g. task_complete held back from a previous batch)
            // so they get their own focused LLM turn.
            if !deferredMessages.isEmpty {
                pendingChannelMessages.append(contentsOf: deferredMessages)
                deferredMessages.removeAll()
            }

            drainPendingMessages()
            checkScheduledWake()
            await pruneHistoryIfNeeded()

            guard hasUnprocessedInput else {
                await idleWait()
                continue
            }

            // If the agent transitioned from idle due to new channel messages,
            // wait for the burst to settle before querying the LLM. This flag
            // is false during an active tool loop, so tool results aren't delayed.
            if debouncingForMessages {
                let debounce = debounceTimeRemaining()
                if debounce > 0 {
                    await idleWait(maxDuration: debounce)
                    continue
                }
                debouncingForMessages = false
            }

            do {
                let activeTasks = await toolContext.taskStore.allTasks().filter { $0.disposition == .active }
                let hasRunnableTasks = activeTasks.contains { $0.status.isRunnable }
                let hasAwaitingReview = activeTasks.contains { $0.status == .awaitingReview }
                let availabilityContext = ToolAvailabilityContext(
                    lastDirectUserMessageAt: lastDirectUserMessageAt,
                    agentRole: configuration.role,
                    hasPendingOrPausedTasks: hasRunnableTasks,
                    hasAwaitingReviewTasks: hasAwaitingReview
                )
                let toolDefinitions = tools
                    .filter { $0.isAvailable(in: availabilityContext) }
                    .map { $0.definition(for: configuration.role) }
                toolContext.onProcessingStateChange(true)
                defer { toolContext.onProcessingStateChange(false) }

                let messagesForLLM = conversationHistory

                let llmStartTime = Date()
                let response = try await provider.send(
                    messages: messagesForLLM,
                    tools: toolDefinitions
                )
                let llmLatencyMs = Int(Date().timeIntervalSince(llmStartTime) * 1000)
                guard isRunning else { break }

                consecutiveErrors = 0
                consecutiveContextOverflows = 0
                let inputDelta = Array(conversationHistory[lastTurnMessageCount...])
                lastTurnMessageCount = conversationHistory.count
                let turnRecord = LLMTurnRecord(
                    inputDelta: inputDelta,
                    response: response,
                    totalMessageCount: conversationHistory.count,
                    contextSnapshot: messagesForLLM,
                    latencyMs: llmLatencyMs,
                    modelID: configuration.llmConfig.model,
                    providerType: configuration.providerAPIType.rawValue,
                    temperature: configuration.llmConfig.temperature,
                    maxOutputTokens: configuration.llmConfig.maxTokens,
                    thinkingBudget: configuration.llmConfig.thinkingBudget,
                    usage: response.usage
                )
                llmTurns.append(turnRecord)
                pruneOldTurnSnapshots()
                onTurnRecorded?(turnRecord)

                // Persist usage record for analytics.
                if let usageStore {
                    let currentTask = await toolContext.taskStore.taskForAgent(agentID: id)
                    await UsageRecorder.record(
                        response: response,
                        context: LLMCallContext(
                            agentRole: configuration.role,
                            taskID: currentTask?.id,
                            modelID: configuration.llmConfig.model,
                            providerType: configuration.providerAPIType.rawValue,
                            configurationID: configuration.llmConfig.id,
                            preResetInputTokens: pendingPreResetTokens
                        ),
                        latencyMs: llmLatencyMs,
                        to: usageStore
                    )
                    pendingPreResetTokens = nil
                }

                try await handleResponse(response)
            } catch {
                guard isRunning else { break }

                // Context overflow: the API rejected the request because messages + completion
                // exceed the model's context window. Rebuild context from task state (Brown)
                // or force-prune (others) and retry immediately — backoff won't help.
                if Self.isContextOverflowError(error) {
                    consecutiveContextOverflows += 1
                    let roleName = configuration.role.displayName

                    if consecutiveContextOverflows <= Self.maxContextOverflowRetries {
                        if configuration.role == .brown {
                            let rebuilt = await rebuildContextFromTask()
                            if !rebuilt {
                                // No running task found — fall back to aggressive prune
                                forceAggressivePrune()
                            }
                        } else {
                            forceAggressivePrune()
                        }
                        await toolContext.channel.post(ChannelMessage(
                            sender: .system,
                            content: "Context overflow for \(roleName) — context rebuilt (attempt \(consecutiveContextOverflows)/\(Self.maxContextOverflowRetries)).",
                            metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                        ))
                        continue  // Retry immediately with smaller context
                    } else {
                        await toolContext.channel.post(ChannelMessage(
                            sender: .system,
                            content: "Agent \(roleName) stopped: context overflow persists after \(Self.maxContextOverflowRetries) rebuild attempts.",
                            metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                        ))
                        isRunning = false
                        break
                    }
                }

                // Log unhandled 400 errors so we can detect patterns that need specific handling.
                Self.logUnhandled400(error)

                consecutiveErrors += 1
                consecutiveContextOverflows = 0  // Reset overflow counter on non-overflow errors

                let backoff = min(
                    3.0 * pow(2.0, Double(min(consecutiveErrors - 1, 10))),
                    Self.maxBackoffSeconds
                )

                // Suppress early transient errors (e.g. 429 rate limits) from the channel.
                // Only start showing errors after 5 consecutive failures.
                if consecutiveErrors >= 5 {
                    await toolContext.channel.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(configuration.role.displayName) error (\(consecutiveErrors)/\(Self.maxConsecutiveErrors)): \(error.localizedDescription)",
                        metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                    ))
                }

                if consecutiveErrors >= Self.maxConsecutiveErrors {
                    await toolContext.channel.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(configuration.role.displayName) stopped after \(Self.maxConsecutiveErrors) consecutive errors.",
                        metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                    ))
                    isRunning = false
                    break
                }

                // Use Task.sleep instead of idleWait — idleWait is interruptible by
                // incoming channel messages (including the error message we just posted),
                // which would cancel the backoff immediately.
                do {
                    try await Task.sleep(for: .seconds(backoff))
                } catch {
                    // Sleep cancelled (agent stopped) — fall through to loop guard
                }
            }
        }
        await toolContext.onSelfTerminate()
    }

    private func handleResponse(_ response: LLMResponse) async throws {
        // Post text to channel unless this agent's raw LLM output is suppressed.
        // Suppressed text is still stored in conversationHistory and visible in the inspector.
        if let text = response.text, !text.isEmpty, !configuration.suppressesRawTextToChannel {
            await toolContext.channel.post(ChannelMessage(
                sender: .agent(configuration.role),
                content: text
            ))
        }

        // For Smith, treat text-only responses as an implicit message_user.
        // In mixed responses (text + tool calls), the text is internal narration
        // (e.g., "Great job, Brown!") not meant for the user — Smith uses
        // message_user explicitly when it wants to address the user.
        var implicitMessageSent = false
        if configuration.role == .smith,
           response.toolCalls.isEmpty,
           let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            await toolContext.channel.post(ChannelMessage(
                sender: .agent(configuration.role),
                recipientID: OrchestrationRuntime.userID,
                recipient: .user,
                content: text
            ))
            implicitMessageSent = true
        }

        let toolCalls = response.toolCalls
        if toolCalls.isEmpty {
            consecutiveTextOnlyResponses += 1
            // Reset tool repetition tracker — a text-only response breaks any tool call streak.
            lastToolCallSignature = nil
            consecutiveIdenticalToolCalls = 0

            // Text-only response — record and wait for new input
            if let text = response.text, !text.isEmpty {
                conversationHistory.append(LLMMessage(role: .assistant, text: text))
                pushLiveContext()

                if configuration.suppressesRawTextToChannel, !implicitMessageSent {
                    appendDiscardedTextWarning()
                }
            }

            // Circuit breaker: if the model keeps returning text without tool calls,
            // it's likely degenerate (repetition loop or unable to use tools). Terminate.
            // Brown (tool-heavy worker) triggers quickly at 6; Smith (conversational orchestrator) at 30.
            let textOnlyLimit = configuration.role == .smith ? 30 : 6
            if consecutiveTextOnlyResponses >= textOnlyLimit {
                await toolContext.channel.post(ChannelMessage(
                    sender: .system,
                    content: "Agent \(configuration.role.displayName) returned \(consecutiveTextOnlyResponses) consecutive text-only responses without calling any tools. Terminating — the model may be in a degenerate loop."
                ))
                await toolContext.onSelfTerminate()
                isRunning = false
                return
            }

            // Mark that we've processed the current input; don't re-query until
            // new messages arrive via the channel.
            hasUnprocessedInput = false
            return
        }

        consecutiveTextOnlyResponses = 0

        // Cap tool calls before recording to history — every recorded tool call must have
        // a matching tool result, or the LLM API will error on the next request.
        let callsToExecute = Array(toolCalls.prefix(maxToolCallsPerIteration))
        if callsToExecute.count < toolCalls.count {
            await toolContext.channel.post(ChannelMessage(
                sender: .system,
                content: "Rate limit: dropped \(toolCalls.count - callsToExecute.count) tool calls (max \(maxToolCallsPerIteration) per iteration)."
            ))
        }

        // Record the assistant message with only the calls we will execute, so that
        // subsequent tool results have a matching request in history.
        if let text = response.text, !text.isEmpty {
            conversationHistory.append(LLMMessage(
                role: .assistant,
                content: .mixed(text: text, toolCalls: callsToExecute)
            ))
            // Note: do NOT call appendDiscardedTextWarning() here. Inserting a user message
            // between the assistant tool_use and the tool_result messages breaks the Anthropic
            // API requirement that tool_results immediately follow their tool_use. Mixed text
            // alongside tool calls is intentional narration, not a problem to warn about.
        } else {
            conversationHistory.append(LLMMessage(
                role: .assistant,
                content: .toolCalls(callsToExecute)
            ))
        }

        var sentMessage = false
        var calledTaskComplete = false
        var calledCreateTask = false

        let taskLifecycleTools: Set<String> = [
            "task_acknowledged", "task_update", "task_complete", "reply_to_user",
            "message_user", "message_brown"
        ]

        // Segment calls into contiguous runs of lifecycle vs approval-needing.
        // Each segment completes before the next starts, preserving ordering.
        // e.g. [task_acknowledged, file_read x10, task_complete] becomes:
        //   segment 0: lifecycle  [task_acknowledged]     → sequential
        //   segment 1: approval   [file_read x10]         → parallel
        //   segment 2: lifecycle  [task_complete]          → sequential
        struct CallSegment {
            let isLifecycle: Bool
            var calls: [LLMToolCall]
        }

        var segments: [CallSegment] = []
        for call in callsToExecute {
            let isLifecycle = taskLifecycleTools.contains(call.name)
            if let last = segments.last, last.isLifecycle == isLifecycle {
                segments[segments.count - 1].calls.append(call)
            } else {
                segments.append(CallSegment(isLifecycle: isLifecycle, calls: [call]))
            }
        }

        var executedCallIDs = Set<String>()

        for segment in segments {
            guard isRunning else { break }

            if segment.isLifecycle {
                // --- Lifecycle segment: execute sequentially, no approval ---
                for call in segment.calls {
                    guard isRunning else { break }
                    let result: String
                    if let tool = tools.first(where: { $0.name == call.name }) {
                        result = await directExecute(call, tool: tool)
                    } else {
                        result = "Unknown tool: \(call.name)"
                    }
                    executedCallIDs.insert(call.id)
                    updatePostCallFlags(call: call, result: result, sentMessage: &sentMessage, calledTaskComplete: &calledTaskComplete, calledCreateTask: &calledCreateTask)
                    conversationHistory.append(LLMMessage(
                        role: .tool,
                        content: .toolResult(toolCallID: call.id, content: Self.capToolResult(result))
                    ))
                    pushLiveContext()
                }
            } else if segment.calls.count > 1 && configuration.requiresToolApproval,
                      let evaluator = securityEvaluator {
                // --- Approval segment with multiple calls: parallel evaluation + execution ---
                let approvalSummaries = segment.calls.map {
                    Self.conciseToolCallSummary(name: $0.name, arguments: $0.arguments)
                }

                struct ParallelEntry: Sendable {
                    let batchIndex: Int
                    let call: LLMToolCall
                    let tool: any AgentTool
                    let siblings: String
                    let taskTitle: String?
                    let taskID: String?
                    let taskDescription: String?
                }

                let allTasks = await toolContext.taskStore.allTasks()
                let currentTask = allTasks.first { $0.assigneeIDs.contains(toolContext.agentID) && $0.status == .running }
                let parallelCount = segment.calls.count

                var entries: [ParallelEntry] = []
                for (batchIndex, call) in segment.calls.enumerated() {
                    guard isRunning else { break }
                    guard let tool = tools.first(where: { $0.name == call.name }) else { continue }
                    let siblings = approvalSummaries.enumerated()
                        .compactMap { $0.offset != batchIndex ? $0.element : nil }
                        .joined(separator: "\n")
                    entries.append(ParallelEntry(
                        batchIndex: batchIndex, call: call, tool: tool, siblings: siblings,
                        taskTitle: currentTask?.title, taskID: currentTask?.id.uuidString,
                        taskDescription: currentTask?.description
                    ))
                    await postToolRequestToChannel(call, tool: tool, task: currentTask, parallelIndex: batchIndex, parallelCount: parallelCount, siblingCallSummaries: approvalSummaries.enumerated().compactMap { $0.offset != batchIndex ? $0.element : nil })
                }

                struct ParallelToolResult: Sendable {
                    let batchIndex: Int
                    let callID: String
                    let result: String
                }

                let channel = toolContext.channel
                let role = configuration.role
                let roleName = configuration.role.displayName
                let ctx = toolContext

                let jonesActiveCount = OSAllocatedUnfairLock(initialState: 0)
                let jonesCallback = ctx.onJonesProcessingStateChange

                // Evaluate + execute a single entry. Extracted so the sliding
                // window doesn't duplicate the task body.
                let evaluateEntry: @Sendable (ParallelEntry) async -> ParallelToolResult = { entry in
                    let toolDef = entry.tool.definition(for: role)
                    let toolParamDefs = AgentActor.formatToolParameterDefinitions(toolDef.parameters)

                    let shouldSignalStart = jonesActiveCount.withLock { count -> Bool in
                        count += 1
                        return count == 1
                    }
                    if shouldSignalStart { jonesCallback(true) }

                    let disposition = await evaluator.evaluate(
                        toolName: entry.call.name,
                        toolParams: entry.call.arguments,
                        toolDescription: toolDef.description,
                        toolParameterDefs: toolParamDefs,
                        taskTitle: entry.taskTitle,
                        taskID: entry.taskID,
                        taskDescription: entry.taskDescription,
                        siblingCalls: entry.siblings.isEmpty ? nil : entry.siblings,
                        agentRoleName: roleName
                    )

                    let shouldSignalEnd = jonesActiveCount.withLock { count -> Bool in
                        count -= 1
                        return count == 0
                    }
                    if shouldSignalEnd { jonesCallback(false) }

                    await AgentActor.postSecurityReviewToChannel(
                        disposition: disposition, call: entry.call, role: role, roleName: roleName, channel: channel
                    )

                    let result: String
                    if disposition.approved {
                        do {
                            let args = try entry.call.parsedArguments()
                            result = try await entry.tool.execute(arguments: args, context: ctx)
                        } catch {
                            result = "Tool error: \(error.localizedDescription)"
                        }
                        await AgentActor.postToolOutputToChannel(
                            result: result, call: entry.call, role: role, channel: channel
                        )
                    } else {
                        if let taskID = currentTask?.id {
                            let update = AgentActor.securityDenialUpdateMessage(
                                call: entry.call, disposition: disposition, isParallelBatch: true
                            )
                            await ctx.taskStore.addUpdate(id: taskID, message: update)
                        }
                        result = "Tool execution denied: \(disposition.message ?? "No reason given")"
                    }

                    return ParallelToolResult(
                        batchIndex: entry.batchIndex, callID: entry.call.id, result: result
                    )
                }

                // Sliding window: at most maxConcurrentEvaluations Jones calls in flight.
                let results: [ParallelToolResult] = await withTaskGroup(
                    of: ParallelToolResult.self,
                    returning: [ParallelToolResult].self
                ) { group in
                    var collected: [ParallelToolResult] = []
                    var iterator = entries.makeIterator()

                    // Seed with up to maxConcurrentEvaluations tasks.
                    for _ in 0..<min(Self.maxConcurrentEvaluations, entries.count) {
                        guard let entry = iterator.next() else { break }
                        group.addTask { await evaluateEntry(entry) }
                    }

                    // As each completes, add the next entry (if any).
                    for await result in group {
                        collected.append(result)
                        if let entry = iterator.next() {
                            group.addTask { await evaluateEntry(entry) }
                        }
                    }

                    return collected
                }

                for r in results.sorted(by: { $0.batchIndex < $1.batchIndex }) {
                    executedCallIDs.insert(r.callID)
                    conversationHistory.append(LLMMessage(
                        role: .tool,
                        content: .toolResult(toolCallID: r.callID, content: Self.capToolResult(r.result))
                    ))
                }
                pushLiveContext()
            } else {
                // --- Sequential approval path (single call or no evaluator) ---
                let approvalSummaries: [String] = segment.calls.count > 1
                    ? segment.calls.map { Self.conciseToolCallSummary(name: $0.name, arguments: $0.arguments) }
                    : []

                for (batchIndex, call) in segment.calls.enumerated() {
                    guard isRunning else { break }
                    let result: String
                    if let tool = tools.first(where: { $0.name == call.name }) {
                        if configuration.requiresToolApproval {
                            let siblings = segment.calls.count > 1
                                ? approvalSummaries.enumerated().compactMap { $0.offset != batchIndex ? $0.element : nil }
                                : []
                            result = await executeWithApproval(call, tool: tool, parallelIndex: batchIndex, parallelCount: segment.calls.count, siblingCallSummaries: siblings)
                        } else {
                            result = await directExecute(call, tool: tool)
                        }
                    } else {
                        result = "Unknown tool: \(call.name)"
                    }
                    executedCallIDs.insert(call.id)
                    updatePostCallFlags(call: call, result: result, sentMessage: &sentMessage, calledTaskComplete: &calledTaskComplete, calledCreateTask: &calledCreateTask)
                    conversationHistory.append(LLMMessage(
                        role: .tool,
                        content: .toolResult(toolCallID: call.id, content: Self.capToolResult(result))
                    ))
                    pushLiveContext()
                }
            }
        }

        // Safety: if any segment loop exited early (stop() during await), append placeholder
        // results for remaining tool_calls to maintain the API invariant.
        var appendedPlaceholders = false
        for call in callsToExecute where !executedCallIDs.contains(call.id) {
            conversationHistory.append(LLMMessage(
                role: .tool,
                content: .toolResult(toolCallID: call.id, content: "Tool execution cancelled (agent stopped)")
            ))
            appendedPlaceholders = true
        }
        if appendedPlaceholders { pushLiveContext() }

        // --- Repetition circuit breaker ---
        // Track consecutive identical tool calls (same name + same normalized arguments).
        // Any different tool call resets the counter. Text-only responses reset separately.
        if let firstCall = callsToExecute.first {
            let sig = Self.toolCallSignature(name: firstCall.name, arguments: firstCall.arguments)
            if sig == lastToolCallSignature {
                consecutiveIdenticalToolCalls += 1
            } else {
                lastToolCallSignature = sig
                consecutiveIdenticalToolCalls = 1
            }
        } else {
            lastToolCallSignature = nil
            consecutiveIdenticalToolCalls = 0
        }

        if consecutiveIdenticalToolCalls >= Self.maxConsecutiveIdenticalToolCalls {
            await toolContext.channel.post(ChannelMessage(
                sender: .system,
                content: "Agent \(configuration.role.displayName) called \(callsToExecute.first?.name ?? "unknown") with identical arguments \(consecutiveIdenticalToolCalls) times in a row. Breaking loop — agent will idle until new input arrives."
            ))
            consecutiveIdenticalToolCalls = 0
            lastToolCallSignature = nil
            hasUnprocessedInput = false
            return
        }

        // run_task fires a detached restart — stop the run loop so we don't
        // race the restart and accidentally trigger it a second time.
        if calledCreateTask {
            hasUnprocessedInput = false
            return
        }

        // After completing a task, stop and wait for Smith's review.
        // This takes priority over the sentMessage check since task_complete also posts a message.
        if calledTaskComplete {
            awaitingTaskReview = true
            hasUnprocessedInput = false
            return
        }

        // After sending an explicit message, stop and wait for a reply rather than continuing
        // to act. This prevents agents from looping by sending the same message repeatedly
        // before anyone has had a chance to respond.
        // Note: implicitMessageSent (Smith's raw text treated as message_user) does NOT
        // trigger this — when the LLM emits text alongside tool calls, the text is narration
        // ("let me check...") and the agent must continue to process tool results.
        if sentMessage {
            hasUnprocessedInput = false
            return
        }

        // Tool results have been appended; the LLM needs to see them on the next iteration.
        // hasUnprocessedInput stays true (it was true when we entered handleResponse).
    }

    /// Appends a warning to conversation history when an agent with suppressed text output
    /// returns non-empty text that was discarded. Nudges the LLM to use structured tools instead.
    private func appendDiscardedTextWarning() {
        conversationHistory.append(LLMMessage(
            role: .user,
            text: "[System] Your text output was discarded — it is not visible to anyone. " +
                  "Use task_update to communicate progress, or task_complete to deliver results."
        ))
    }

    /// Evaluates a tool call via SecurityEvaluator, posts channel messages, executes if approved.
    /// Used for sequential tool calls that require approval.
    private func executeWithApproval(_ call: LLMToolCall, tool: any AgentTool, parallelIndex: Int = 0, parallelCount: Int = 1, siblingCallSummaries: [String] = []) async -> String {
        let toolDef = tool.definition(for: configuration.role)
        let toolParameterDefs = Self.formatToolParameterDefinitions(toolDef.parameters)

        // Look up the current running task for context.
        let allTasks = await toolContext.taskStore.allTasks()
        let currentTask = allTasks.first { $0.assigneeIDs.contains(toolContext.agentID) && $0.status == .running }

        // Post tool_request to channel for UI visibility.
        await postToolRequestToChannel(call, tool: tool, task: currentTask, parallelIndex: parallelIndex, parallelCount: parallelCount, siblingCallSummaries: siblingCallSummaries)

        guard let evaluator = securityEvaluator else {
            assertionFailure("Brown requires tool approval but no SecurityEvaluator is configured")
            Self.agentLogger.error("Tool '\(call.name, privacy: .public)' denied — no SecurityEvaluator configured. This is a configuration bug.")
            return "Tool execution denied: No security evaluator is configured. Tool cannot be executed without approval."
        }

        let siblings = siblingCallSummaries.isEmpty ? nil : siblingCallSummaries.joined(separator: "\n")
        toolContext.onJonesProcessingStateChange(true)
        let disposition = await evaluator.evaluate(
            toolName: call.name,
            toolParams: call.arguments,
            toolDescription: toolDef.description,
            toolParameterDefs: toolParameterDefs,
            taskTitle: currentTask?.title,
            taskID: currentTask?.id.uuidString,
            taskDescription: currentTask?.description,
            siblingCalls: siblings,
            agentRoleName: configuration.role.displayName
        )
        toolContext.onJonesProcessingStateChange(false)

        // Post approval/denial status.
        await Self.postSecurityReviewToChannel(
            disposition: disposition, call: call, role: configuration.role,
            roleName: configuration.role.displayName, channel: toolContext.channel
        )

        if disposition.approved {
            let result = await directExecute(call, tool: tool)
            await Self.postToolOutputToChannel(
                result: result, call: call, role: configuration.role, channel: toolContext.channel
            )
            return result
        } else {
            if let task = currentTask {
                let update = Self.securityDenialUpdateMessage(
                    call: call, disposition: disposition, isParallelBatch: parallelCount > 1
                )
                await toolContext.taskStore.addUpdate(id: task.id, message: update)
            }
            return "Tool execution denied: \(disposition.message ?? "No reason given")"
        }
    }

    private func directExecute(_ call: LLMToolCall, tool: any AgentTool) async -> String {
        do {
            let args = try call.parsedArguments()
            return try await tool.execute(arguments: args, context: toolContext)
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    // MARK: - Channel posting helpers

    /// Posts a tool_request message to the channel for UI visibility.
    private func postToolRequestToChannel(_ call: LLMToolCall, tool: any AgentTool, task: AgentTask?, parallelIndex: Int, parallelCount: Int, siblingCallSummaries: [String]) async {
        let toolDef = tool.definition(for: configuration.role)
        let toolParameterDefs = Self.formatToolParameterDefinitions(toolDef.parameters)

        var metadata: [String: AnyCodable] = [
            "messageKind": .string("tool_request"),
            "requestID": .string(call.id),
            "agentID": .string(toolContext.agentID.uuidString),
            "tool": .string(call.name),
            "params": .string(call.arguments),
            "toolDescription": .string(toolDef.description),
            "toolParameters": .string(toolParameterDefs)
        ]
        if let task {
            metadata["taskTitle"] = .string(task.title)
            metadata["taskID"] = .string(task.id.uuidString)
            metadata["taskDescription"] = .string(task.description)
        }
        if parallelCount > 1 {
            metadata["parallelIndex"] = .int(parallelIndex)
            metadata["parallelCount"] = .int(parallelCount)
            if !siblingCallSummaries.isEmpty {
                metadata["siblingCalls"] = .string(siblingCallSummaries.joined(separator: "\n"))
            }
        }
        if call.name == "file_write", let args = Self.parseToolParams(call.arguments) {
            if case .string(let path) = args["path"] { metadata["fileWritePath"] = .string(path) }
            if case .string(let content) = args["content"] { metadata["fileWriteContent"] = .string(content) }
        }

        await toolContext.channel.post(ChannelMessage(
            sender: .agent(configuration.role),
            content: Self.conciseToolCallSummary(name: call.name, arguments: call.arguments),
            metadata: metadata
        ))
    }

    /// Posts a security review status message to the channel. Static so it can be called from `withTaskGroup`.
    static func postSecurityReviewToChannel(disposition: SecurityDisposition, call: LLMToolCall, role: AgentRole, roleName: String, channel: MessageChannel) async {
        let statusContent: String
        let securityDisposition: String
        if disposition.approved && disposition.isAutoApproval {
            statusContent = "Auto-approved (WARN retry)"
            securityDisposition = "autoApproved"
        } else if disposition.approved {
            statusContent = "Jones → \(roleName): SAFE\(disposition.message.map { " \($0)" } ?? "")"
            securityDisposition = "approved"
        } else if disposition.isWarning {
            let warnSummary = disposition.message?.components(separatedBy: "\n").first ?? ""
            statusContent = "Jones → \(roleName): WARN: \(warnSummary)"
            securityDisposition = "warning"
        } else {
            statusContent = "Jones → \(roleName): UNSAFE: \(disposition.message ?? "no reason given")"
            securityDisposition = "denied"
        }
        var reviewMetadata: [String: AnyCodable] = [
            "requestID": .string(call.id),
            "securityDisposition": .string(securityDisposition),
            "agentRole": .string(role.rawValue)
        ]
        if let msg = disposition.message, !msg.isEmpty {
            reviewMetadata["dispositionMessage"] = .string(msg)
        }
        await channel.post(ChannelMessage(
            sender: .system,
            content: statusContent,
            metadata: reviewMetadata
        ))
    }

    /// Posts tool output to the channel. Static so it can be called from `withTaskGroup`.
    ///
    /// The channel message stores only the display-truncated version of the output to avoid
    /// bloating the SwiftUI view layer with megabytes of data (e.g., binary blobs from osascript).
    static func postToolOutputToChannel(result: String, call: LLMToolCall, role: AgentRole, channel: MessageChannel) async {
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else { return }
        let truncated = AgentActor.truncateOutput(trimmedResult, maxLines: 4)
        let isTruncated = truncated != trimmedResult
        var outputMetadata: [String: AnyCodable] = [
            "requestID": .string(call.id),
            "messageKind": .string("tool_output"),
            "tool": .string(call.name)
        ]
        if isTruncated {
            outputMetadata["truncatedContent"] = .string(truncated)
            // Store a larger excerpt for "Show more" — cap at 10K to avoid bloating the UI.
            let expandedLimit = 10_000
            if trimmedResult.count > expandedLimit {
                let remaining = trimmedResult.count - expandedLimit
                outputMetadata["expandedContent"] = .string(
                    String(trimmedResult.prefix(expandedLimit)) + "\n… (\(remaining) more characters, see conversation history)"
                )
            } else {
                outputMetadata["expandedContent"] = .string(trimmedResult)
            }
        }
        await channel.post(ChannelMessage(
            sender: .agent(role),
            content: isTruncated ? truncated : trimmedResult,
            metadata: outputMetadata
        ))
    }

    /// Tool result strings used for post-call control flow. Keep in sync with tool return values.
    private func updatePostCallFlags(call: LLMToolCall, result: String, sentMessage: inout Bool, calledTaskComplete: inout Bool, calledCreateTask: inout Bool) {
        if call.name == "message_user" && result == "Message sent to user." { sentMessage = true }
        if call.name == "review_work" && (result.contains("accepted and completed") || result.contains("Feedback sent to Brown")) { sentMessage = true }
        if call.name == "message_brown" && result == "Message sent to Brown." { sentMessage = true }
        if call.name == "reply_to_user" && result == "Reply sent to user." { sentMessage = true }
        if call.name == "task_complete" && result.hasPrefix("Task submitted for review:") { calledTaskComplete = true }
        if call.name == "run_task" && result.contains("System is restarting") { calledCreateTask = true }
    }

    // MARK: - Wake / sleep helpers

    /// Cancels the current idle sleep, causing the run loop to re-evaluate immediately.
    private func interruptIdleSleep() {
        idleSleepTask?.cancel()
    }

    /// Sleeps for up to `maxDuration` seconds, or until interrupted by a new message
    /// or a scheduled follow-up that becomes due sooner.
    private func idleWait(maxDuration: TimeInterval? = nil) async {
        var duration = maxDuration ?? pollInterval
        if let wakeAt = scheduledWakeAt {
            let untilWake = max(0, wakeAt.timeIntervalSinceNow)
            duration = min(duration, untilWake)
        }
        duration = max(0.1, duration)

        let task = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(duration)) } catch { }
        }
        idleSleepTask = task
        // withTaskCancellationHandler ensures that if the run loop task itself is
        // cancelled (e.g., via stop()), we immediately cancel the inner sleep rather
        // than waiting for the full duration.
        await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        idleSleepTask = nil
    }

    /// Returns how many seconds remain in the post-message debounce window, or 0 if settled.
    private func debounceTimeRemaining() -> TimeInterval {
        guard let last = lastChannelMessageAt else { return 0 }
        return max(0, messageDebounceInterval - Date().timeIntervalSince(last))
    }

    /// Fires a scheduled follow-up if its deadline has arrived, injecting a reminder
    /// into the conversation so the LLM knows to review the current state.
    private func checkScheduledWake() {
        guard let wakeAt = scheduledWakeAt, Date() >= wakeAt else { return }
        guard !awaitingTaskReview else {
            // Don't wake during task review — the scheduled timer is stale.
            scheduledWakeAt = nil
            return
        }
        scheduledWakeAt = nil
        conversationHistory.append(LLMMessage(
            role: .user,
            text: "[System: Your scheduled follow-up timer has elapsed. Review the current state and continue as appropriate.]"
        ))
        hasUnprocessedInput = true
        pushLiveContext()
    }

    /// Notifies the UI layer that the conversation history has changed.
    private func pushLiveContext() {
        onContextChanged?(conversationHistory)
    }

    /// Caps the turn record count and strips contextSnapshot from older turns.
    private func pruneOldTurnSnapshots() {
        // Drop oldest records when exceeding the hard cap.
        if llmTurns.count > Self.maxTurnRecords {
            llmTurns.removeFirst(llmTurns.count - Self.maxTurnRecords)
        }
        // Strip heavy snapshots from turns outside the recent window.
        let stripCount = llmTurns.count - Self.recentSnapshotWindow
        guard stripCount > 0 else { return }
        for i in 0..<stripCount where !llmTurns[i].contextSnapshot.isEmpty {
            llmTurns[i].stripContextSnapshot()
        }
    }

    private func drainPendingMessages() {
        guard !pendingChannelMessages.isEmpty else { return }

        // When awaiting task review, only wake if a private message addressed to this
        // agent arrived (Smith sending revision feedback). Other messages (system banners,
        // public notifications) are still drained into history but don't trigger a new LLM call.
        if awaitingTaskReview {
            let hasPrivateMessage = pendingChannelMessages.contains { $0.recipientID == id }
            if hasPrivateMessage {
                awaitingTaskReview = false
                hasUnprocessedInput = true
            }
            // else: drain messages into history below, but leave hasUnprocessedInput as-is
        } else {
            // Separate task_complete messages from the batch so they get their own LLM turn.
            // This prevents the review trigger from being buried in a merged text blob.
            let hasTaskComplete = pendingChannelMessages.contains { msg in
                if case .string("task_complete") = msg.metadata?["messageKind"] { return true }
                return false
            }
            let hasOtherMessages = pendingChannelMessages.contains { msg in
                if case .string("task_complete") = msg.metadata?["messageKind"] { return false }
                return true
            }

            if hasTaskComplete && hasOtherMessages {
                // Split: defer task_complete messages, drain everything else now.
                let taskCompleteMessages = pendingChannelMessages.filter { msg in
                    if case .string("task_complete") = msg.metadata?["messageKind"] { return true }
                    return false
                }
                pendingChannelMessages.removeAll { msg in
                    if case .string("task_complete") = msg.metadata?["messageKind"] { return true }
                    return false
                }
                deferredMessages.append(contentsOf: taskCompleteMessages)
            }

            // Lifecycle and agent_online messages are informational — drain them into
            // history for context but don't trigger a new LLM call. Only messages that
            // require Smith's action (user messages, task_complete, errors) should wake it.
            let nonWakingKinds: Set<String> = ["task_lifecycle", "task_acknowledged", "agent_online"]
            let hasActionableMessage = pendingChannelMessages.contains { msg in
                if case .string(let kind) = msg.metadata?["messageKind"],
                   nonWakingKinds.contains(kind) {
                    return false
                }
                return true
            }
            if hasActionableMessage {
                hasUnprocessedInput = true
            }
        }

        // Collect all images across pending messages
        var allImages: [LLMImageContent] = []
        var allTextParts: [String] = []

        for message in pendingChannelMessages {
            let senderLabel: String
            switch message.sender {
            case .user:
                senderLabel = "USER (\(message.sender.displayName))"
            case .agent:
                senderLabel = "AGENT \(message.sender.displayName)"
            case .system:
                senderLabel = "SYSTEM"
            }
            let formatted = "[\(senderLabel)]: \(message.content)"

            let imageAttachments = message.attachments.filter(\.isImage)
            for attachment in imageAttachments {
                guard let data = attachment.data else { continue }
                allImages.append(LLMImageContent(data: data, mimeType: attachment.mimeType))
            }

            var textParts = [formatted]
            let nonImageAttachments = message.attachments.filter { !$0.isImage }
            for attachment in nonImageAttachments {
                textParts.append("[Attached file: \(attachment.filename) (\(attachment.mimeType), \(attachment.formattedSize))]")
            }

            allTextParts.append(textParts.joined(separator: "\n"))
        }
        pendingChannelMessages.removeAll()

        let combinedText = allTextParts.joined(separator: "\n\n")
        let images: [LLMImageContent]? = allImages.isEmpty ? nil : allImages

        // If the last history entry is already a user message (e.g. a prior LLM call failed
        // before producing an assistant response), merge into it to maintain the strict
        // user/assistant alternation that some model APIs require.
        if let lastIndex = conversationHistory.indices.last,
           conversationHistory[lastIndex].role == .user,
           case .text(let existingText) = conversationHistory[lastIndex].content {
            let merged = existingText + "\n\n" + combinedText
            // Combine images from both the existing message and new messages
            let existingImages = conversationHistory[lastIndex].images
            let mergedImages: [LLMImageContent]? = {
                let combined = (existingImages ?? []) + (images ?? [])
                return combined.isEmpty ? nil : combined
            }()
            conversationHistory[lastIndex] = LLMMessage(
                role: .user,
                text: merged,
                images: mergedImages
            )
        } else {
            conversationHistory.append(LLMMessage(
                role: .user,
                text: combinedText,
                images: images
            ))
        }
        pushLiveContext()
    }

    /// Formats tool parameter definitions from a JSON Schema parameters dictionary into a human-readable string.
    static func formatToolParameterDefinitions(_ parameters: [String: AnyCodable]) -> String {
        guard case .dictionary(let properties) = parameters["properties"] else {
            return ""
        }
        var lines: [String] = []
        for (name, value) in properties.sorted(by: { $0.key < $1.key }) {
            var parts = ["- parameter name: \(name)"]
            if case .dictionary(let paramDict) = value {
                if case .string(let desc) = paramDict["description"] {
                    parts.append("- parameter description: \(desc)")
                }
            }
            lines.append(parts.joined(separator: "\n"))
        }
        return lines.enumerated()
            .map { "tool parameter \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n")
    }

    /// Formats a tool call as a concise one-liner for channel display, e.g. `"bash: ls -la ~/"`.
    /// Produces a short human-readable description for a tool call.
    /// For `file_write`, returns just `file_write <path>` — the view layer renders rich formatting
    /// using the structured metadata fields (`fileWritePath`, `fileWriteContent`).
    private static func conciseToolCallSummary(name: String, arguments: String) -> String {
        guard let data = arguments.data(using: .utf8) else {
            return "\(name): \(arguments)"
        }
        let dict: [String: AnyCodable]
        do {
            dict = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        } catch {
            // Malformed JSON from the LLM — fall back to raw arguments string.
            return "\(name): \(arguments)"
        }

        // file_write gets a compact one-liner; the view layer adds rich formatting.
        if name == "file_write", case .string(let path) = dict["path"] {
            return "file_write \(path)"
        }

        // For single-argument tools, just show the value directly
        if dict.count == 1, let value = dict.values.first {
            return "\(name): \(Self.anyCodableToString(value))"
        }

        // For multi-argument tools, show key=value pairs
        let pairs = dict.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(Self.anyCodableToString($0.value))" }
            .joined(separator: ", ")
        return "\(name): \(pairs)"
    }

    private static func anyCodableToString(_ value: AnyCodable) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array, .dictionary:
            do {
                let data = try JSONEncoder().encode(value)
                return String(data: data, encoding: .utf8) ?? String(describing: value)
            } catch {
                return String(describing: value)
            }
        }
    }

    /// JSON encoder with sorted keys for deterministic argument normalization.
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Computes a deduplication signature for a tool call: "toolName|hash(normalizedArgs)".
    /// Arguments are decoded and re-encoded with sorted keys so that JSON key order doesn't matter.
    private static func toolCallSignature(name: String, arguments: String) -> String {
        if let data = arguments.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
           let normalized = try? sortedEncoder.encode(dict),
           let normalizedString = String(data: normalized, encoding: .utf8) {
            return "\(name)|\(normalizedString.hashValue)"
        }
        return "\(name)|\(arguments.hashValue)"
    }

    /// Maximum characters for a tool result stored in conversation history.
    /// Prevents massive outputs (e.g., binary blobs, multi-MB command output) from blowing up LLM context.
    private static let maxToolResultCharacters = 50_000

    /// Maximum characters per argument value in security denial task updates.
    private static let maxArgCharsForUpdate = 50

    static func securityDenialUpdateMessage(
        call: LLMToolCall,
        disposition: SecurityDisposition,
        isParallelBatch: Bool
    ) -> String {
        let label = disposition.isWarning ? "WARN" : "UNSAFE"
        let reason = disposition.message ?? "no reason given"
        let batchNote = isParallelBatch ? " (part of parallel batch)" : ""

        // Truncate each argument value to keep updates readable.
        let truncatedArgs: String
        do {
            guard let data = call.arguments.data(using: .utf8) else {
                throw NSError(domain: "AgentActor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Non-UTF8 arguments"])
            }
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "AgentActor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Arguments not a JSON object"])
            }
            let pairs = dict.map { key, value in
                let raw = String(describing: value)
                let capped = raw.count > maxArgCharsForUpdate
                    ? String(raw.prefix(maxArgCharsForUpdate)) + "…"
                    : raw
                return "\"\(key)\": \"\(capped)\""
            }
            truncatedArgs = pairs.joined(separator: ", ")
        } catch {
            let raw = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            truncatedArgs = raw.count > maxArgCharsForUpdate
                ? String(raw.prefix(maxArgCharsForUpdate)) + "…"
                : raw
        }

        return """
            Tool call "\(call.name)"\(batchNote) execution denied by security agent:
            - Arguments: \(truncatedArgs)
            - Security response: \(label) \(reason)
            """
    }

    /// Caps a tool result string for conversation history, preserving the head and noting truncation.
    static func capToolResult(_ result: String) -> String {
        guard result.count > maxToolResultCharacters else { return result }
        let remaining = result.count - maxToolResultCharacters
        return String(result.prefix(maxToolResultCharacters)) + "\n\n[Output truncated — \(remaining) more characters omitted]"
    }

    /// Truncates multi-line output to a limited number of lines, appending an ellipsis indicator if truncated.
    private static let maxOutputCharacters = 500

    private static func truncateOutput(_ text: String, maxLines: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        var result = trimmed
        var didTruncate = false

        // Truncate by line count
        if lines.count > maxLines {
            result = lines.prefix(maxLines).joined(separator: "\n")
            result += "\n… (\(lines.count - maxLines) more lines)"
            didTruncate = true
        }

        // Truncate by character count
        if result.count > maxOutputCharacters {
            let remaining = trimmed.count - maxOutputCharacters
            result = String(result.prefix(maxOutputCharacters)) + "… (\(remaining) more characters)"
            didTruncate = true
        }

        return didTruncate ? result : trimmed
    }

    /// Parses a JSON string into an AnyCodable dictionary for structural comparison.
    private static func parseToolParams(_ json: String) -> [String: AnyCodable]? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([String: AnyCodable].self, from: data)
        } catch {
            // Malformed JSON — return nil so comparison falls through to normal evaluation.
            return nil
        }
    }


    /// Prunes conversation history when approaching the context window limit.
    ///
    /// The available input budget is `contextWindowSize - maxTokens` (the output reservation).
    /// Pruning triggers at 80% of that budget to leave headroom for estimation inaccuracy.
    ///
    /// **Brown** uses task-state rebuild: replaces the entire conversation with a fresh task
    /// instruction synthesized from the task's current state (description, progress updates,
    /// memories, prior tasks) plus the last complete tool call/result exchange for continuity.
    /// This avoids the fragile tool-pair stitching problem and preserves all meaningful context.
    ///
    /// **Non-Brown agents** use a sliding-window prune that keeps ~35% of recent messages.
    private func pruneHistoryIfNeeded() async {
        // ~3 characters per token as a conservative estimate.
        // Include tool definitions and per-turn suffix overhead (not stored in history
        // but sent with every API call and counted against the context window).
        let estimatedTokens = (conversationHistory.reduce(0) {
            $0 + $1.estimatedCharacterCount
        } + apiOverheadChars) / 3

        // The input budget is the context window minus the output token reservation.
        // Without this subtraction, pruning triggers far too late for models where
        // maxTokens is a large fraction of contextWindowSize (e.g., deepseek-reasoner
        // with 65K output in a 131K window).
        let contextLimit = configuration.llmConfig.contextWindowSize
        // Floor at 25% of context window to handle misconfigured maxTokens gracefully.
        let inputBudget = max(contextLimit / 4, contextLimit - configuration.llmConfig.maxTokens)
        let pruneThreshold = inputBudget * 4 / 5

        guard estimatedTokens > pruneThreshold else { return }

        // Capture last known input tokens before reset for analytics.
        pendingPreResetTokens = llmTurns.last?.usage?.inputTokens

        if configuration.role == .brown {
            // Brown rebuilds from task state — clean, no tool-pair stitching issues.
            let rebuilt = await rebuildContextFromTask()
            if !rebuilt {
                // No running task — fall back to aggressive prune as a last resort.
                forceAggressivePrune()
            }
            return
        }

        // Non-Brown sliding-window prune (Smith doesn't use tool calls the same way).
        pruneNonBrownHistory(inputBudget: inputBudget)
    }

    /// Sliding-window prune for non-Brown agents. Keeps ~35% of recent messages.
    private func pruneNonBrownHistory(inputBudget: Int) {
        let targetTokens = inputBudget * 7 / 20
        var keptTokens = 0
        var keepFromIndex = conversationHistory.count

        for i in stride(from: conversationHistory.count - 1, through: 1, by: -1) {
            let msgTokens = conversationHistory[i].estimatedCharacterCount / 3
            if keptTokens + msgTokens > targetTokens {
                break
            }
            keptTokens += msgTokens
            keepFromIndex = i
        }

        // If we couldn't fit anything, still keep the most recent message.
        if keepFromIndex >= conversationHistory.count {
            keepFromIndex = conversationHistory.count - 1
        }

        // If all messages appeared to fit (zero/underestimated token counts), force-prune
        // the oldest half to prevent unbounded growth despite the token threshold being exceeded.
        if keepFromIndex == 1 {
            keepFromIndex = max(2, conversationHistory.count / 2)
        }

        // Don't split tool call/result pairs — back up past any orphaned tool results.
        while keepFromIndex > 1, conversationHistory[keepFromIndex].role == .tool {
            keepFromIndex -= 1
        }

        // If the tool walk-back collapsed to index 1, force a minimal prune from index 2
        // so we always make forward progress against the context limit.
        if keepFromIndex <= 1 {
            guard conversationHistory.count > 2 else { return }
            keepFromIndex = 2
        }

        let prunedCount = keepFromIndex - 1
        guard prunedCount > 0 else { return }

        var newHistory = [conversationHistory[0]]  // System prompt
        newHistory.append(LLMMessage(
            role: .user,
            text: "[System: \(prunedCount) earlier messages were pruned to stay within context limits. Continue from the recent context below.]"
        ))
        newHistory.append(contentsOf: conversationHistory[keepFromIndex...])
        conversationHistory = newHistory
        lastTurnMessageCount = conversationHistory.count
        pushLiveContext()

        let roleName = configuration.role.displayName
        let channel = toolContext.channel
        Task.detached {
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Context pruned for \(roleName): removed \(prunedCount) old messages."
            ))
        }
    }

    /// Detects whether an error is a context overflow (the request exceeded the model's context window).
    /// Matches the error body patterns from OpenAI-compatible APIs (DeepSeek, Mistral, etc.).
    private static func isContextOverflowError(_ error: Error) -> Bool {
        guard let providerError = error as? LLMProviderError,
              case .httpError(let statusCode, let body, _) = providerError else {
            return false
        }
        // HTTP 400 with body indicating the request exceeded the model's context window.
        // Each pattern matches a substantial, provider-specific substring to avoid false
        // positives. Unmatched 400s are logged by logUnhandled400 so we can add new patterns.
        //
        // Known formats:
        // - OpenAI/DeepSeek/Mistral: "This model's maximum context length is N tokens"
        // - OpenAI error code: "context_length_exceeded"
        // - Anthropic: "prompt is too long: N tokens"
        // - Generic: "Please reduce the length of the messages"
        if statusCode == 400 {
            let lower = body.lowercased()
            return lower.contains("maximum context length is")
                || lower.contains("context_length_exceeded")
                || lower.contains("reduce the length of the messages")
                || lower.contains("prompt is too long:")
        }
        return false
    }

    /// Emergency prune for non-Brown agents: keeps system prompt and the most recent 20%
    /// of messages. Brown uses `rebuildContextFromTask` instead.
    private func forceAggressivePrune() {
        guard conversationHistory.count > 3 else { return }

        // Keep only the most recent ~20% of messages (by count, not tokens)
        let keepCount = max(4, conversationHistory.count / 5)
        var keepFromIndex = conversationHistory.count - keepCount

        // Don't split tool call/result pairs
        while keepFromIndex > 1, conversationHistory[keepFromIndex].role == .tool {
            keepFromIndex -= 1
        }
        keepFromIndex = max(1, keepFromIndex)

        let prunedCount = keepFromIndex - 1
        guard prunedCount > 0 else { return }

        var newHistory = [conversationHistory[0]]  // System prompt
        newHistory.append(LLMMessage(
            role: .user,
            text: "[System: \(prunedCount) earlier messages were aggressively pruned after a context overflow error. Continue from the recent context below.]"
        ))
        newHistory.append(contentsOf: conversationHistory[keepFromIndex...])
        conversationHistory = newHistory
        lastTurnMessageCount = conversationHistory.count
        pushLiveContext()

        let roleName = configuration.role.displayName
        let channel = toolContext.channel
        Task.detached {
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Aggressively pruned \(prunedCount) messages for \(roleName) (no running task for rebuild)."
            ))
        }
    }

    /// Rebuilds Brown's conversation history from the current running task's data.
    ///
    /// Completely replaces the conversation history with:
    /// 1. The original system prompt
    /// 2. A synthesized task instruction built from the task's current state (title, description,
    ///    all progress updates, relevant memories/prior tasks)
    /// 3. The last complete assistant + tool-result exchange from the old history (for continuity)
    ///
    /// This is far more efficient than pruning because task updates are a compressed log
    /// of accomplishments (~1 line each) vs the verbose tool call/result pairs they replaced.
    /// It also eliminates tool-pair stitching bugs that can cause API errors.
    ///
    /// - Returns: `true` if a running task was found and context was rebuilt; `false` otherwise.
    private func rebuildContextFromTask() async -> Bool {
        let allTasks = await toolContext.taskStore.allTasks()
        guard let task = allTasks.first(where: { $0.status == .running }) else {
            return false
        }

        // Extract the last complete tool exchange before clearing history.
        let lastExchange = extractLastToolExchange()

        // Post a task update so the rebuild is visible in the task's progress log.
        await toolContext.taskStore.addUpdate(
            id: task.id,
            message: "Context cleared due to size limits — rebuilding from task state and continuing work."
        )

        // Rebuild conversation: system prompt + fresh task instruction.
        var parts: [String] = []

        if let memories = task.relevantMemories, !memories.isEmpty {
            let memoryLines = memories.map { "- \($0.content) (similarity: \(String(format: "%.2f", $0.similarity)))" }
            parts.append("Relevant memories:\n\(memoryLines.joined(separator: "\n"))")
        }
        if let priorTasks = task.relevantPriorTasks, !priorTasks.isEmpty {
            let taskLines = priorTasks.map { priorTask in
                "- \(priorTask.title): \(priorTask.summary) (similarity: \(String(format: "%.2f", priorTask.similarity))) — full details: `get_task_details(task_id: \"\(priorTask.taskID.uuidString)\")`"
            }
            parts.append("Relevant prior task summaries:\n\(taskLines.joined(separator: "\n"))")
        }

        parts.append("""
            Task: "\(task.title)"
            Task ID: \(task.id.uuidString)

            \(task.description)
            """)

        if !task.updates.isEmpty {
            let history = task.updates.map { "- \($0.message)" }.joined(separator: "\n")
            parts.append("Progress so far:\n\(history)")
        }

        if let brownContext = task.lastBrownContext {
            parts.append("Last known working state:\n\(brownContext)")
        }

        parts.append("""
            Your conversation history was cleared because it exceeded the model's context window. \
            The task progress above reflects your work so far. Continue working on this task from where you left off. \
            Do not repeat work that the progress updates show is already done.
            """)

        let instruction = parts.joined(separator: "\n\n")

        conversationHistory = [
            conversationHistory[0],  // System prompt
            LLMMessage(role: .user, text: instruction)
        ]

        // Append the last complete tool exchange so Brown has immediate continuity
        // with what it just did. This is always a valid sequence: assistant (with toolCalls)
        // followed by all its matching tool result messages.
        //
        // Guard against infinite rebuild loops: if the base history plus the last exchange
        // would still exceed the prune threshold, drop the exchange. The task's progress
        // updates already capture what was accomplished.
        if !lastExchange.isEmpty {
            let contextLimit = configuration.llmConfig.contextWindowSize
            let inputBudget = max(contextLimit / 4, contextLimit - configuration.llmConfig.maxTokens)
            let pruneThreshold = inputBudget * 4 / 5

            let baseChars = conversationHistory.reduce(0) { $0 + $1.estimatedCharacterCount }
            let exchangeChars = lastExchange.reduce(0) { $0 + $1.estimatedCharacterCount }
            let estimatedTokens = (baseChars + exchangeChars + apiOverheadChars) / 3

            if estimatedTokens <= pruneThreshold {
                conversationHistory.append(contentsOf: lastExchange)
            }
        }

        lastTurnMessageCount = conversationHistory.count
        llmTurns.removeAll()
        hasUnprocessedInput = true
        pushLiveContext()

        let channel = toolContext.channel
        let prunedLabel = configuration.role.displayName
        Task.detached {
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Context rebuilt for \(prunedLabel) from task state."
            ))
        }

        return true
    }

    /// Extracts the last complete assistant + tool-result exchange from conversation history.
    ///
    /// Walks backward to find the last assistant message that contains tool calls, then
    /// collects all consecutive `.tool` result messages that follow it. Returns the
    /// complete sequence (assistant + tool results) or an empty array if none found.
    private func extractLastToolExchange() -> [LLMMessage] {
        // Find the last assistant message with tool calls.
        var assistantIndex: Int?
        for i in stride(from: conversationHistory.count - 1, through: 0, by: -1) {
            let msg = conversationHistory[i]
            guard msg.role == .assistant else { continue }
            switch msg.content {
            case .toolCalls, .mixed:
                assistantIndex = i
            default:
                continue
            }
            break
        }

        guard let aIdx = assistantIndex else { return [] }

        // Collect the assistant message and all consecutive tool results after it.
        var exchange = [conversationHistory[aIdx]]
        var nextIdx = aIdx + 1
        while nextIdx < conversationHistory.count, conversationHistory[nextIdx].role == .tool {
            exchange.append(conversationHistory[nextIdx])
            nextIdx += 1
        }

        // Only return if we have at least one tool result (a complete pair).
        return exchange.count >= 2 ? exchange : []
    }

    /// Logs HTTP 400 errors that were NOT classified as context overflow, so we can
    /// detect patterns that may need specific handling in the future.
    private static let agentLogger = Logger(subsystem: "com.agentsmith", category: "AgentActor")

    private static func logUnhandled400(_ error: Error) {
        guard let providerError = error as? LLMProviderError,
              case .httpError(let statusCode, let body, let url) = providerError,
              statusCode == 400 else {
            return
        }
        agentLogger.warning(
            "Unhandled HTTP 400 (not context overflow): url=\(url?.absoluteString ?? "unknown", privacy: .public) body=\(body.prefix(500), privacy: .public)"
        )
    }

}
