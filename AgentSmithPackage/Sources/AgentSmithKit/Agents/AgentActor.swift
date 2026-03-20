import Foundation

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

    /// Gate used by Brown to submit tool-approval requests to Jones.
    private var toolRequestGate: ToolRequestGate?

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
    private static let maxConsecutiveErrors = 10
    private static let maxBackoffSeconds: Double = 60
    private var maxToolCallsPerIteration: Int

    /// Per-turn LLM call log for per-turn inspection.
    private var llmTurns: [LLMTurnRecord] = []
    /// Message count at the time of the previous LLM call — used to compute inputDelta.
    private var lastTurnMessageCount: Int = 0
    private static let maxTurnRecords = 30

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

        conversationHistory.append(LLMMessage(
            role: .system,
            text: configuration.systemPrompt
        ))
    }

    /// Injects the tool-request gate used for Brown's approval flow.
    public func setToolRequestGate(_ gate: ToolRequestGate) {
        toolRequestGate = gate
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
    }

    /// Updates the idle poll interval for this agent.
    public func updatePollInterval(_ interval: TimeInterval) {
        pollInterval = interval
    }

    /// Updates the maximum number of tool calls executed per LLM response.
    public func updateMaxToolCalls(_ count: Int) {
        maxToolCallsPerIteration = count
    }

    /// Schedules a follow-up wake after the given delay.
    /// If a sooner wake is already scheduled, this call is ignored.
    public func scheduleFollowUp(after delay: TimeInterval) {
        let newWakeAt = Date().addingTimeInterval(delay)
        if let existing = scheduledWakeAt, existing <= newWakeAt {
            return
        }
        scheduledWakeAt = newWakeAt
        interruptIdleSleep()
    }

    /// Starts the agent's run loop.
    public func start(initialInstruction: String? = nil) {
        guard !isRunning else { return }
        isRunning = true

        if let instruction = initialInstruction {
            conversationHistory.append(LLMMessage(role: .user, text: instruction))
            hasUnprocessedInput = true
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
    /// - Agents with `messageFilter == .toolRequestsOnly` only receive public tool_request messages;
    ///   all private messages are also dropped under this filter.
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

        // Strict filter: only public tool_request messages get through. All private messages
        // (including from the user) are dropped so this agent only processes tool requests.
        if configuration.messageFilter == .toolRequestsOnly {
            if message.recipientID != nil { return }
            guard case .string(let kind) = message.metadata?["messageKind"],
                  kind == "tool_request" else { return }
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
            drainPendingMessages()
            checkScheduledWake()
            pruneHistoryIfNeeded()

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
                let availabilityContext = ToolAvailabilityContext(
                    lastDirectUserMessageAt: lastDirectUserMessageAt,
                    agentRole: configuration.role
                )
                let toolDefinitions = tools
                    .filter { $0.isAvailable(in: availabilityContext) }
                    .map { $0.definition(for: configuration.role) }
                toolContext.onProcessingStateChange(true)
                defer { toolContext.onProcessingStateChange(false) }
                let response = try await provider.send(
                    messages: conversationHistory,
                    tools: toolDefinitions
                )
                guard isRunning else { break }

                consecutiveErrors = 0
                let inputDelta = Array(conversationHistory[lastTurnMessageCount...])
                lastTurnMessageCount = conversationHistory.count
                llmTurns.append(LLMTurnRecord(
                    inputDelta: inputDelta,
                    response: response,
                    totalMessageCount: conversationHistory.count
                ))
                if llmTurns.count > Self.maxTurnRecords {
                    llmTurns.removeFirst(llmTurns.count - Self.maxTurnRecords)
                }
                try await handleResponse(response)
            } catch {
                guard isRunning else { break }
                consecutiveErrors += 1

                let backoff = min(
                    pow(2.0, Double(min(consecutiveErrors, 6))),
                    Self.maxBackoffSeconds
                )

                await toolContext.channel.post(ChannelMessage(
                    sender: .system,
                    content: "Agent \(configuration.role.displayName) error (\(consecutiveErrors)/\(Self.maxConsecutiveErrors)): \(error.localizedDescription)",
                    metadata: ["isError": .bool(true)]
                ))

                if consecutiveErrors >= Self.maxConsecutiveErrors {
                    await toolContext.channel.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(configuration.role.displayName) stopped after \(Self.maxConsecutiveErrors) consecutive errors.",
                        metadata: ["isError": .bool(true)]
                    ))
                    isRunning = false
                    break
                }

                await idleWait(maxDuration: backoff)
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

        let toolCalls = response.toolCalls
        if toolCalls.isEmpty {
            // Text-only response — record and wait for new input
            if let text = response.text, !text.isEmpty {
                conversationHistory.append(LLMMessage(role: .assistant, text: text))
            }
            // Mark that we've processed the current input; don't re-query until
            // new messages arrive via the channel.
            hasUnprocessedInput = false
            return
        }

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
        } else {
            conversationHistory.append(LLMMessage(
                role: .assistant,
                content: .toolCalls(callsToExecute)
            ))
        }

        var sentMessage = false
        var spawnedBrown = false
        var calledTaskComplete = false
        for call in callsToExecute {
            guard isRunning else { break }

            let result: String
            // Look up tool from the full array — not the filtered list — so tools available
            // at definition time but whose window expired during the LLM call still execute.
            if let tool = tools.first(where: { $0.name == call.name }) {
                let taskLifecycleTools: Set<String> = [
                    "task_acknowledged", "task_update", "task_complete", "reply_to_user",
                    "send_message"
                ]
                if configuration.requiresToolApproval && !taskLifecycleTools.contains(call.name) {
                    result = await executeWithApproval(call, tool: tool)
                } else {
                    result = await directExecute(call, tool: tool)
                }
            } else {
                result = "Unknown tool: \(call.name)"
            }

            if call.name == "send_message" { sentMessage = true }
            if call.name == "spawn_brown" { spawnedBrown = true }
            if call.name == "task_complete" { calledTaskComplete = true }

            conversationHistory.append(LLMMessage(
                role: .tool,
                content: .toolResult(toolCallID: call.id, content: result)
            ))
        }

        // After completing a task, stop and wait for Smith's review.
        // This takes priority over the sentMessage check since task_complete also posts a message.
        if calledTaskComplete {
            hasUnprocessedInput = false
            return
        }

        // After sending a message, stop and wait for a reply rather than continuing to act.
        // This prevents agents from looping by sending the same message repeatedly before
        // anyone has had a chance to respond.
        if sentMessage {
            hasUnprocessedInput = false
            return
        }

        // After spawning Brown (without also sending it a message in the same turn), stop
        // the loop to prevent spawn storms. Schedule a short follow-up so Smith wakes to
        // send Brown its task instructions — Brown's online announcement is filtered, so
        // nothing else would wake Smith without this.
        if spawnedBrown {
            hasUnprocessedInput = false
            await toolContext.scheduleFollowUp(10)
            return
        }

        // Tool results have been appended; the LLM needs to see them on the next iteration.
        // hasUnprocessedInput stays true (it was true when we entered handleResponse).
    }

    /// Posts a tool_request approval message to the channel, then suspends until Jones resolves it.
    /// Posts a system status message so Smith can track approval outcomes.
    private func executeWithApproval(_ call: LLMToolCall, tool: any AgentTool) async -> String {
        let requestID = UUID()

        await toolContext.channel.post(ChannelMessage(
            sender: .agent(configuration.role),
            content: "Tool request [\(requestID.uuidString)] from agent \(toolContext.agentID.uuidString): \(call.name) \(call.arguments)",
            metadata: [
                "messageKind": .string("tool_request"),
                "requestID": .string(requestID.uuidString),
                "agentID": .string(toolContext.agentID.uuidString),
                "tool": .string(call.name),
                "params": .string(call.arguments)
            ]
        ))

        guard let gate = toolRequestGate else {
            // This should never happen — Brown always receives a gate via setToolRequestGate.
            assertionFailure("Brown requires tool approval but no ToolRequestGate is configured")
            return await directExecute(call, tool: tool)
        }

        let disposition = await gate.wait(for: requestID)

        // Post approval/denial status so Smith can see the outcome without waiting for Brown's report.
        let statusContent: String
        if disposition.approved {
            let note = disposition.message.map { " (⚠️ \($0))" } ?? ""
            statusContent = "Security review: \(call.name) approved\(note)"
        } else if let msg = disposition.message, SystemCancellationReason.allMessages.contains(msg) {
            statusContent = "Tool request cancelled: \(call.name) — \(msg)"
        } else {
            statusContent = "Security review: \(call.name) denied — \(disposition.message ?? "no reason given")"
        }
        await toolContext.channel.post(ChannelMessage(
            sender: .system,
            content: statusContent
        ))

        if disposition.approved {
            return await directExecute(call, tool: tool)
        } else {
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
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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
        scheduledWakeAt = nil
        conversationHistory.append(LLMMessage(
            role: .user,
            text: "[System: Your scheduled follow-up timer has elapsed. Review the current state and continue as appropriate.]"
        ))
        hasUnprocessedInput = true
    }

    private func drainPendingMessages() {
        guard !pendingChannelMessages.isEmpty else { return }
        hasUnprocessedInput = true

        // Collect all images across pending messages
        var allImages: [LLMImageContent] = []
        var allTextParts: [String] = []

        for message in pendingChannelMessages {
            let formatted = "[\(message.sender.displayName)]: \(message.content)"

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
    }

    /// Prunes conversation history when approaching the context window limit.
    private func pruneHistoryIfNeeded() {
        // ~3 characters per token as a conservative estimate
        let estimatedTokens = conversationHistory.reduce(0) {
            $0 + $1.estimatedCharacterCount / 3
        }

        let contextLimit = configuration.llmConfig.contextWindowSize
        let pruneThreshold = contextLimit * 3 / 4

        guard estimatedTokens > pruneThreshold else { return }

        // Keep enough recent messages to fill ~50% of context
        let targetTokens = contextLimit / 2
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

        // If we couldn't fit anything, still keep the most recent message
        if keepFromIndex >= conversationHistory.count {
            keepFromIndex = conversationHistory.count - 1
        }

        // If all messages appeared to fit (zero/underestimated token counts), force-prune
        // the oldest half to prevent unbounded growth despite the token threshold being exceeded.
        if keepFromIndex == 1 {
            keepFromIndex = max(2, conversationHistory.count / 2)
        }

        // Don't split tool call/result pairs — back up past any orphaned tool results
        while keepFromIndex > 1, conversationHistory[keepFromIndex].role == .tool {
            keepFromIndex -= 1
        }

        // If the tool walk-back collapsed to index 1, force a minimal prune from index 2
        // so we always make forward progress against the context limit.
        if keepFromIndex <= 1 {
            guard conversationHistory.count > 2 else { return }
            keepFromIndex = 2
        }

        // Brown retains its system prompt plus the initial task instruction(s) so it never
        // forgets what it was asked to do, even after many tool call rounds cause pruning.
        let retainHead = configuration.role == .brown ? min(3, conversationHistory.count) : 1
        let tailStart = max(keepFromIndex, retainHead)
        let prunedCount = tailStart - retainHead
        guard prunedCount > 0 else { return }

        var newHistory = Array(conversationHistory.prefix(retainHead))
        newHistory.append(LLMMessage(
            role: .user,
            text: "[System: \(prunedCount) earlier messages were pruned to stay within context limits. Continue from the recent context below.]"
        ))
        newHistory.append(contentsOf: conversationHistory[tailStart...])
        conversationHistory = newHistory
        // After pruning, reset the turn baseline so the next turn's delta doesn't
        // use a stale index that would be out of bounds.
        lastTurnMessageCount = conversationHistory.count

        // Post a notification about pruning. channel.post doesn't throw,
        // so this detached Task won't eat errors.
        let roleName = configuration.role.displayName
        let channel = toolContext.channel
        Task.detached {
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Context pruned for \(roleName): removed \(prunedCount) old messages."
            ))
        }
    }
}
