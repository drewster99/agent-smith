import Foundation

/// Core agent actor: owns an LLM session, subscribes to the channel,
/// runs an async loop of receive -> LLM -> act -> report.
public actor AgentActor {
    public let id: UUID
    public let configuration: AgentConfiguration
    private let provider: any LLMProvider
    private let tools: [any AgentTool]
    // internal (not private) so AgentActor+Sanitize.swift can access it.
    let toolContext: ToolContext

    // internal (not private) so AgentActor+Sanitize.swift can access it.
    var conversationHistory: [LLMMessage] = []
    private var isRunning = false
    private var runTask: Task<Void, Never>?

    /// Gate used by Brown to submit tool-approval requests to Jones,
    /// and by Jones to resolve them from parsed text responses.
    private var toolRequestGate: ToolRequestGate?

    /// The request ID from the most recent tool_request message Jones is evaluating.
    private var pendingSecurityRequestID: UUID?
    /// Ring buffer of recent tool request summaries for Jones's evaluation context.
    private var recentToolRequestSummaries: [String] = []
    /// Tracks consecutive parse failures when Jones's text response doesn't match SAFE/WARN/UNSAFE/ABORT.
    private var jonesRetryCount = 0
    private static let maxJonesRetries = 10
    private static let maxRecentToolRequests = 10

    /// Tracks the last WARN'd tool request so Jones can auto-approve an identical retry.
    private var lastWarnedToolName: String?
    private var lastWarnedToolParams: [String: AnyCodable]?
    /// The tool name and parsed params of the request currently being evaluated by Jones.
    private var currentEvalToolName: String?
    private var currentEvalToolParams: [String: AnyCodable]?
    /// Set by `drainPendingMessagesForJones` when an auto-approval is detected; resolved in the run loop.
    private var pendingAutoApproval: UUID?

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
    private var maxToolCallsPerIteration: Int

    /// Per-turn LLM call log for per-turn inspection.
    private var llmTurns: [LLMTurnRecord] = []
    /// Message count at the time of the previous LLM call — used to compute inputDelta.
    // internal (not private) so AgentActor+Sanitize.swift can access it.
    var lastTurnMessageCount: Int = 0
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

        // Drop UI-only notification messages that no agent needs to process.
        if case .string(let kind) = message.metadata?["messageKind"], kind == "task_created" {
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
            drainPendingMessages()
            await resolveAutoApprovedRequests()
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

                // Inject per-turn task context for Smith so it always knows current task state.
                var messagesForLLM = conversationHistory
                if configuration.role == .smith {
                    let taskSuffix = await buildTaskContextSuffix()
                    if !taskSuffix.isEmpty {
                        messagesForLLM.append(LLMMessage(role: .system, text: taskSuffix))
                    }
                }

                let response = try await provider.send(
                    messages: messagesForLLM,
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
                    3.0 * pow(2.0, Double(min(consecutiveErrors - 1, 10))),
                    Self.maxBackoffSeconds
                )

                await toolContext.channel.post(ChannelMessage(
                    sender: .system,
                    content: "Agent \(configuration.role.displayName) error (\(consecutiveErrors)/\(Self.maxConsecutiveErrors)): \(error.localizedDescription)",
                    metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                ))

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
            // Text-only response — record and wait for new input
            if let text = response.text, !text.isEmpty {
                conversationHistory.append(LLMMessage(role: .assistant, text: text))

                // Jones resolves the pending security gate from its text response.
                if configuration.role == .jones, let gate = toolRequestGate {
                    await resolveGateFromText(text, gate: gate)
                    // resolveGateFromText may set hasUnprocessedInput = true on parse failure
                    return
                }

                if configuration.suppressesRawTextToChannel, !implicitMessageSent {
                    appendDiscardedTextWarning()
                }
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
        var spawnedBrown = false
        var calledTaskComplete = false
        var calledCreateTask = false
        for call in callsToExecute {
            guard isRunning else { break }

            let result: String
            // Look up tool from the full array — not the filtered list — so tools available
            // at definition time but whose window expired during the LLM call still execute.
            if let tool = tools.first(where: { $0.name == call.name }) {
                let taskLifecycleTools: Set<String> = [
                    "task_acknowledged", "task_update", "task_complete", "reply_to_user",
                    "message_user", "message_brown"
                ]
                if configuration.requiresToolApproval && !taskLifecycleTools.contains(call.name) {
                    result = await executeWithApproval(call, tool: tool)
                } else {
                    result = await directExecute(call, tool: tool)
                }
            } else {
                result = "Unknown tool: \(call.name)"
            }

            if call.name == "message_user" || call.name == "message_brown" { sentMessage = true }
            if call.name == "spawn_brown" { spawnedBrown = true }
            if call.name == "task_complete" { calledTaskComplete = true }
            if call.name == "create_task" { calledCreateTask = true }

            conversationHistory.append(LLMMessage(
                role: .tool,
                content: .toolResult(toolCallID: call.id, content: result)
            ))
        }

        // create_task fires a detached restart — stop the run loop so we don't
        // race the restart and accidentally call create_task a second time.
        if calledCreateTask {
            hasUnprocessedInput = false
            return
        }

        // After completing a task, stop and wait for Smith's review.
        // This takes priority over the sentMessage check since task_complete also posts a message.
        if calledTaskComplete {
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

        // After spawning Brown (without also sending it a message in the same turn), stop
        // the loop to prevent spawn storms. Brown's agent_online announcement passes through
        // Smith's message filter and will wake Smith to send task instructions.
        if spawnedBrown {
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

    /// Posts a tool_request approval message to the channel, then suspends until Jones resolves it.
    /// Posts a system status message so Smith can track approval outcomes.
    private func executeWithApproval(_ call: LLMToolCall, tool: any AgentTool) async -> String {
        let requestID = UUID()

        let toolDef = tool.definition(for: configuration.role)
        let toolParameterDefs = Self.formatToolParameterDefinitions(toolDef.parameters)

        // Look up the current running task for context
        let allTasks = await toolContext.taskStore.allTasks()
        let currentTask = allTasks.first { $0.assigneeIDs.contains(toolContext.agentID) && $0.status == .running }

        var metadata: [String: AnyCodable] = [
            "messageKind": .string("tool_request"),
            "requestID": .string(requestID.uuidString),
            "agentID": .string(toolContext.agentID.uuidString),
            "tool": .string(call.name),
            "params": .string(call.arguments),
            "toolDescription": .string(toolDef.description),
            "toolParameters": .string(toolParameterDefs)
        ]

        if let task = currentTask {
            metadata["taskTitle"] = .string(task.title)
            metadata["taskID"] = .string(task.id.uuidString)
            metadata["taskDescription"] = .string(task.description)
        }

        // Attach structured fields for file_write so the view layer can render rich formatting.
        if call.name == "file_write",
           let args = Self.parseToolParams(call.arguments) {
            if case .string(let path) = args["path"] {
                metadata["fileWritePath"] = .string(path)
            }
            if case .string(let content) = args["content"] {
                metadata["fileWriteContent"] = .string(content)
            }
        }

        await toolContext.channel.post(ChannelMessage(
            sender: .agent(configuration.role),
            content: Self.conciseToolCallSummary(name: call.name, arguments: call.arguments),
            metadata: metadata
        ))

        guard let gate = toolRequestGate else {
            // This should never happen — Brown always receives a gate via setToolRequestGate.
            assertionFailure("Brown requires tool approval but no ToolRequestGate is configured")
            return await directExecute(call, tool: tool)
        }

        let disposition = await gate.wait(for: requestID)

        // Post approval/denial status so Smith can see the outcome without waiting for Brown's report.
        let statusContent: String
        let securityDisposition: String
        if disposition.approved && disposition.isAutoApproval {
            statusContent = "Auto-approved (WARN retry)"
            securityDisposition = "autoApproved"
        } else if disposition.approved {
            statusContent = "Jones → \(configuration.role.displayName): SAFE"
            securityDisposition = "approved"
        } else if disposition.isWarning {
            // Show only the warning text, not the retry instruction appended to the message.
            let warnSummary = disposition.message?.components(separatedBy: "\n").first ?? ""
            statusContent = "Jones → \(configuration.role.displayName): WARN: \(warnSummary)"
            securityDisposition = "warning"
        } else if let msg = disposition.message, SystemCancellationReason.allMessages.contains(msg) {
            statusContent = "Tool request cancelled: \(call.name) — \(msg)"
            securityDisposition = "cancelled"
        } else {
            statusContent = "Jones → \(configuration.role.displayName): UNSAFE: \(disposition.message ?? "no reason given")"
            securityDisposition = "denied"
        }
        var reviewMetadata: [String: AnyCodable] = [
            "securityDisposition": .string(securityDisposition),
            "agentRole": .string(configuration.role.rawValue),
            "requestID": .string(requestID.uuidString)
        ]
        if let msg = disposition.message, !msg.isEmpty {
            reviewMetadata["dispositionMessage"] = .string(msg)
        }
        await toolContext.channel.post(ChannelMessage(
            sender: .system,
            content: statusContent,
            metadata: reviewMetadata
        ))

        if disposition.approved {
            let result = await directExecute(call, tool: tool)
            // Post full tool output to the channel; the view layer handles truncation.
            let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedResult.isEmpty {
                var outputMetadata: [String: AnyCodable] = [
                    "messageKind": .string("tool_output"),
                    "tool": .string(call.name),
                    "requestID": .string(requestID.uuidString)
                ]
                let truncated = Self.truncateOutput(trimmedResult, maxLines: 4)
                if truncated != trimmedResult {
                    outputMetadata["truncatedContent"] = .string(truncated)
                }
                await toolContext.channel.post(ChannelMessage(
                    sender: .agent(configuration.role),
                    content: trimmedResult,
                    metadata: outputMetadata
                ))
            }
            return result
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

        // Jones uses a structured prompt format for tool request evaluation.
        if configuration.role == .jones, toolRequestGate != nil {
            drainPendingMessagesForJones()
            return
        }

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

    // MARK: - Jones text-based gate resolution

    /// Formats tool_request messages into Jones's structured evaluation prompt.
    private func drainPendingMessagesForJones() {
        guard let message = pendingChannelMessages.last else { return }
        pendingChannelMessages.removeAll()

        // Extract request metadata
        let requestID: UUID?
        if case .string(let idStr) = message.metadata?["requestID"] {
            requestID = UUID(uuidString: idStr)
        } else {
            requestID = nil
        }

        let toolName: String
        if case .string(let name) = message.metadata?["tool"] {
            toolName = name
        } else {
            toolName = "unknown"
        }

        let paramsString: String
        if case .string(let p) = message.metadata?["params"] {
            paramsString = p
        } else {
            paramsString = "{}"
        }

        let parsedParams = Self.parseToolParams(paramsString)

        // Auto-approve if this is an identical retry of a WARN'd request.
        // The retry must be the very next tool call — any different request clears the warning.
        if let warnedTool = lastWarnedToolName,
           let warnedParams = lastWarnedToolParams,
           let reqID = requestID,
           warnedTool == toolName,
           parsedParams == warnedParams {
            lastWarnedToolName = nil
            lastWarnedToolParams = nil
            pendingSecurityRequestID = nil
            pendingAutoApproval = reqID
            recentToolRequestSummaries.append("\(toolName) \(paramsString)")
            if recentToolRequestSummaries.count > Self.maxRecentToolRequests {
                recentToolRequestSummaries.removeFirst()
            }
            hasUnprocessedInput = false
            return
        }
        lastWarnedToolName = nil
        lastWarnedToolParams = nil

        pendingSecurityRequestID = requestID
        currentEvalToolName = toolName
        currentEvalToolParams = parsedParams

        let toolDescription: String
        if case .string(let desc) = message.metadata?["toolDescription"] {
            toolDescription = desc
        } else {
            toolDescription = "No description available"
        }

        let toolParameterDefs: String
        if case .string(let defs) = message.metadata?["toolParameters"] {
            toolParameterDefs = defs
        } else {
            toolParameterDefs = ""
        }

        // Track recent tool calls for context
        recentToolRequestSummaries.append("\(toolName) \(paramsString)")
        if recentToolRequestSummaries.count > Self.maxRecentToolRequests {
            recentToolRequestSummaries.removeFirst()
        }

        // Build structured evaluation prompt
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let dateStr = dateFormatter.string(from: Date())

        var sections: [String] = []
        sections.append("The current date and time are \(dateStr)")

        // Task context (if available)
        if case .string(let title) = message.metadata?["taskTitle"],
           case .string(let taskID) = message.metadata?["taskID"] {
            let desc: String
            if case .string(let d) = message.metadata?["taskDescription"] {
                desc = d
            } else {
                desc = ""
            }
            sections.append("""
                # Current task
                - title: \(title)
                - identifier: \(taskID)
                - description: \(desc)
                """)
        }

        // Recent tool call history
        if !recentToolRequestSummaries.isEmpty {
            let recent = recentToolRequestSummaries.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            sections.append("# Recent tool calls (for context):\n\(recent)")
        }

        // The tool request to evaluate
        var requestSection = """
            # Your task:
            Evaluate the following tool request, in the context of the current task and recent tool calls (above) for data integrity, security and safety:

            ## Tool description
            \(toolDescription)
            
            ## Tool call to evaluate:
            - tool name: \(toolName)
            - parameters: \(paramsString)
            
            """
        if !toolParameterDefs.isEmpty {
            requestSection += "\n\(toolParameterDefs)"
        }
        requestSection += """

            # Response
            Plain text reponse with no markdown, JSON or XML formatting, as one of the following options:
            
            ## Option 1 -- tool call is safe to run (approved):
            SAFE <any logic or commentary>

            ## Option 2 -- this tool call or the pattern of recent tool calls appears unsafe to
            run, but **MIGHT** be okay, *considering the user's stated intent in the task description*:
            WARN <terse message text follows on same line>

            ## Option 3 -- this tool call or the recent pattern of tool calls is unsafe and
            should not be run:
            UNSAFE <terse text explaining why>

            ## Option 4 -- this tool call or the pattern established by recent history is
            incredibly unsafe, presenting an immediate danger to the user's data, data
            integrity, system integrity, the user's health, safety or well-being, or another
            human's health, safety, or well-being, or is otherwise of a destructive and
            unwanted nature:
            ABORT <brief terse text explaining why>

            ## If you are uncertain as to how to respond, respond with WARN.

            Your response will be processed by an automated system, so it is REQUIRED that you MUST respond with a SINGLE LINE OF TEXT that begins with one of those 4 words (SAFE, WARN, UNSAFE, ABORT).
            """
        sections.append(requestSection)

        let combinedText = sections.joined(separator: "\n\n")

        // Jones never needs prior eval/response pairs — reset to just [system, eval prompt].
        // The recent tool call history embedded in the eval prompt provides all needed context.
        let systemMessage = conversationHistory[0]
        conversationHistory = [systemMessage, LLMMessage(role: .user, text: combinedText)]
        lastTurnMessageCount = conversationHistory.count
    }

    /// Parses Jones's text response for a security disposition keyword and resolves the gate.
    private func resolveGateFromText(_ text: String, gate: ToolRequestGate) async {
        guard let requestID = pendingSecurityRequestID else {
            hasUnprocessedInput = false
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLineEnd = trimmed.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? trimmed.endIndex
        let firstLine = String(trimmed[trimmed.startIndex..<firstLineEnd])
        let words = firstLine.split(separator: " ", maxSplits: 1)

        guard let keyword = words.first else {
            await handleJonesParseFailure()
            return
        }

        let keywordUpper = keyword.uppercased()

        // Collect all explanatory text: rest of first line + subsequent lines
        let explanatoryText: String? = {
            var parts: [String] = []
            if words.count > 1 {
                parts.append(String(words[1]))
            }
            if firstLineEnd < trimmed.endIndex {
                let rest = String(trimmed[trimmed.index(after: firstLineEnd)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    parts.append(rest)
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }()

        let disposition: SecurityDisposition
        switch keywordUpper {
        case "SAFE":
            disposition = SecurityDisposition(approved: true)
        case "WARN":
            // WARN denies the request but allows an identical retry as the very next tool call.
            lastWarnedToolName = currentEvalToolName
            lastWarnedToolParams = currentEvalToolParams
            let warnText = (explanatoryText ?? "") + "\nYour tool was not allowed to execute. Carefully consider the security response text above, in the context of the user's original intent (as given in the task description) and other actions taken and interactions and decide if you really want to call this tool. If you do, send *exactly* the same request again as your *very next* tool call, and it will be approved."
            disposition = SecurityDisposition(approved: false, message: warnText, isWarning: true)
        case "UNSAFE":
            disposition = SecurityDisposition(approved: false, message: explanatoryText)
        case "ABORT":
            disposition = SecurityDisposition(approved: false, message: explanatoryText)
            // Post the abort disposition before triggering the abort so the sound
            // system sees it before all agents are torn down.
            await toolContext.channel.post(ChannelMessage(
                sender: .system,
                content: "Security review: ABORT — \(explanatoryText ?? "Jones triggered abort")",
                metadata: [
                    "securityDisposition": .string("abort"),
                    "agentRole": .string(AgentRole.jones.rawValue)
                ]
            ))
            await toolContext.abort(explanatoryText ?? "Jones triggered abort", .jones)
        default:
            await handleJonesParseFailure()
            return
        }

        jonesRetryCount = 0
        pendingSecurityRequestID = nil
        currentEvalToolName = nil
        currentEvalToolParams = nil
        hasUnprocessedInput = false
        await gate.resolve(requestID: requestID, disposition: disposition)
    }

    /// Handles a parse failure from Jones's text response by appending a retry prompt.
    private func handleJonesParseFailure() async {
        jonesRetryCount += 1

        if jonesRetryCount >= Self.maxJonesRetries {
            // Give up — resolve as denied after too many failures
            if let requestID = pendingSecurityRequestID, let gate = toolRequestGate {
                pendingSecurityRequestID = nil
                jonesRetryCount = 0
                await gate.resolve(
                    requestID: requestID,
                    disposition: SecurityDisposition(
                        approved: false,
                        message: "Security evaluation failed after \(Self.maxJonesRetries) attempts"
                    )
                )
            }
            hasUnprocessedInput = false
            return
        }

        // Exponential backoff starting from the 2nd retry (3rd total attempt)
        if jonesRetryCount > 1 {
            let delay = min(pow(2.0, Double(jonesRetryCount - 1)), 32.0)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Task cancelled during backoff — still proceed with retry
            }
        }

        conversationHistory.append(LLMMessage(
            role: .user,
            text: "Please respond with one of SAFE, WARN, UNSAFE or ABORT -- and no other text, formatting, JSON, XML, markdown or commentary."
        ))
        hasUnprocessedInput = true
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

    /// Formats a tool call as a concise one-liner for channel display, e.g. `"shell: ls -la ~/"`.
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

    /// Resolves a pending auto-approved request (from a WARN retry) if one exists.
    /// No status message is posted here — `executeWithApproval` posts its own status
    /// when the gate resolves, which avoids duplicate channel messages.
    private func resolveAutoApprovedRequests() async {
        guard let requestID = pendingAutoApproval, let gate = toolRequestGate else { return }
        pendingAutoApproval = nil
        await gate.resolve(requestID: requestID, disposition: SecurityDisposition(approved: true, isAutoApproval: true))
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

        // Jones: trim recentToolRequestSummaries instead of pruning messages.
        // Jones's history is always [system, eval prompt] — the only variable-size content
        // is the recent tool call history embedded in the eval prompt text.
        // The trimmed list takes effect on the next drainPendingMessagesForJones call.
        if configuration.role == .jones {
            guard !recentToolRequestSummaries.isEmpty else { return }
            let removeCount = max(1, recentToolRequestSummaries.count / 2)
            recentToolRequestSummaries.removeFirst(removeCount)
            return
        }

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

    // MARK: - Per-turn task context (Smith only)

    /// Builds a system prompt suffix summarizing active tasks for Smith's situational awareness.
    /// Includes up to 5 in-progress tasks with previews; remaining tasks are summarized as a count.
    private func buildTaskContextSuffix() async -> String {
        let allTasks = await toolContext.taskStore.allTasks()
        let activeTasks = allTasks.filter { $0.disposition == .active }
        guard !activeTasks.isEmpty else {
            return "[Current task state: No active tasks. Use list_tasks to check for tasks in other dispositions.]"
        }

        let maxInlined = 5
        var lines: [String] = ["[Current task state as of this turn:]"]
        for task in activeTasks.prefix(maxInlined) {
            var entry = "• \(task.title) (id: \(task.id.uuidString)) — status: \(task.status.rawValue)"
            if !task.description.isEmpty {
                let descPreview = task.description.prefix(200)
                entry += "\n  Description: \(descPreview)\(task.description.count > 200 ? "…" : "")"
            }
            if let result = task.result, !result.isEmpty {
                let resultPreview = result.prefix(200)
                entry += "\n  Result: \(resultPreview)\(result.count > 200 ? "…" : "")"
            }
            lines.append(entry)
        }
        let remaining = activeTasks.count - maxInlined
        if remaining > 0 {
            lines.append("…plus \(remaining) more active task\(remaining == 1 ? "" : "s"). Use list_tasks to fetch additional details.")
        }
        lines.append("Use list_tasks to fetch full details including complete descriptions and results.")
        return lines.joined(separator: "\n")
    }
}
