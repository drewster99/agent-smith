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

    /// Messages from the channel that arrived while waiting for the LLM.
    private var pendingChannelMessages: [ChannelMessage] = []

    /// Whether the agent has unprocessed input that requires an LLM call.
    /// Prevents re-querying the LLM with identical context after a text-only response.
    private var hasUnprocessedInput = false

    /// Tracks consecutive LLM errors for exponential backoff.
    private var consecutiveErrors = 0
    private static let maxConsecutiveErrors = 10
    private static let maxBackoffSeconds: Double = 60
    private static let maxToolCallsPerIteration = 10

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

        conversationHistory.append(LLMMessage(
            role: .system,
            text: configuration.systemPrompt
        ))
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
                content: "\(role.displayName) agent \(agentID) is online."
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

        pendingChannelMessages.append(message)
    }

    /// Whether the agent is currently running.
    public var running: Bool {
        isRunning
    }

    // MARK: - Private

    private func runLoop() async {
        while isRunning, !Task.isCancelled {
            drainPendingMessages()
            pruneHistoryIfNeeded()

            guard hasUnprocessedInput else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            do {
                let toolDefinitions = tools.map(\.definition)
                let response = try await provider.send(
                    messages: conversationHistory,
                    tools: toolDefinitions
                )
                guard isRunning else { break }

                consecutiveErrors = 0
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
                    content: "Agent \(configuration.role.displayName) error (\(consecutiveErrors)/\(Self.maxConsecutiveErrors)): \(error.localizedDescription)"
                ))

                if consecutiveErrors >= Self.maxConsecutiveErrors {
                    await toolContext.channel.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(configuration.role.displayName) stopped after \(Self.maxConsecutiveErrors) consecutive errors."
                    ))
                    isRunning = false
                    break
                }

                try? await Task.sleep(for: .seconds(backoff))
            }
        }
        await toolContext.onSelfTerminate()
    }

    private func handleResponse(_ response: LLMResponse) async throws {
        // Post any text to channel for display
        if let text = response.text, !text.isEmpty {
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
        let callsToExecute = Array(toolCalls.prefix(Self.maxToolCallsPerIteration))
        if callsToExecute.count < toolCalls.count {
            await toolContext.channel.post(ChannelMessage(
                sender: .system,
                content: "Rate limit: dropped \(toolCalls.count - callsToExecute.count) tool calls (max \(Self.maxToolCallsPerIteration) per iteration)."
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

        for call in callsToExecute {
            guard isRunning else { break }

            let result: String
            if let tool = tools.first(where: { $0.name == call.name }) {
                do {
                    let args = try call.parsedArguments()
                    result = try await tool.execute(arguments: args, context: toolContext)
                } catch {
                    result = "Tool error: \(error.localizedDescription)"
                }
            } else {
                result = "Unknown tool: \(call.name)"
            }

            conversationHistory.append(LLMMessage(
                role: .tool,
                content: .toolResult(toolCallID: call.id, content: result)
            ))
        }

        // Tool results have been appended; the LLM needs to see them on the next iteration.
        // hasUnprocessedInput stays true (it was true when we entered handleResponse).
    }

    private func drainPendingMessages() {
        guard !pendingChannelMessages.isEmpty else { return }
        hasUnprocessedInput = true

        for message in pendingChannelMessages {
            let formatted = "[\(message.sender.displayName)]: \(message.content)"

            // Convert image attachments to multimodal LLM content
            let images: [LLMImageContent]? = {
                let imageAttachments = message.attachments.filter(\.isImage)
                guard !imageAttachments.isEmpty else { return nil }
                return imageAttachments.compactMap { attachment in
                    guard let data = attachment.data else { return nil }
                    return LLMImageContent(data: data, mimeType: attachment.mimeType)
                }
            }()

            // For non-image attachments, append a text description
            var textParts = [formatted]
            let nonImageAttachments = message.attachments.filter { !$0.isImage }
            for attachment in nonImageAttachments {
                textParts.append("[Attached file: \(attachment.filename) (\(attachment.mimeType), \(attachment.formattedSize))]")
            }

            conversationHistory.append(LLMMessage(
                role: .user,
                text: textParts.joined(separator: "\n"),
                images: images
            ))
        }
        pendingChannelMessages.removeAll()
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

        let prunedCount = keepFromIndex - 1
        guard prunedCount > 0 else { return }

        var newHistory = [conversationHistory[0]]
        newHistory.append(LLMMessage(
            role: .user,
            text: "[System: \(prunedCount) earlier messages were pruned to stay within context limits. Continue from the recent context below.]"
        ))
        newHistory.append(contentsOf: conversationHistory[keepFromIndex...])
        conversationHistory = newHistory

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
