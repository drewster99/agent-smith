import Foundation

/// The outcome of a security evaluation of a tool request.
public struct SecurityDisposition: Sendable {
    public let approved: Bool
    /// Explanation — required when denied, recommended for medium-risk warnings.
    public let message: String?
    /// True when this is a WARN denial — the request can be retried once for auto-approval.
    public let isWarning: Bool
    /// True when this approval was automatic (identical retry of a WARN'd request).
    public let isAutoApproval: Bool

    public init(approved: Bool, message: String? = nil, isWarning: Bool = false, isAutoApproval: Bool = false) {
        self.approved = approved
        self.message = message
        self.isWarning = isWarning
        self.isAutoApproval = isAutoApproval
    }
}

/// Record of a single security evaluation for inspector display.
public struct EvaluationRecord: Sendable, Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let toolName: String
    public let toolParams: String
    public let taskTitle: String?
    public let prompt: String
    public let response: String
    public let disposition: SecurityDisposition
    public let latencyMs: Int
}

/// Direct security evaluator that replaces the Jones agent actor.
///
/// Makes LLM calls using Jones's model configuration to evaluate tool requests.
/// Thread-safe — can be called concurrently for parallel tool call batches.
/// Each Brown agent gets its own evaluator instance; state dies with Brown.
public actor SecurityEvaluator {
    private let provider: any LLMProvider
    private let systemPrompt: String
    private let channel: MessageChannel
    private let abort: @Sendable (String, AgentRole) async -> Void

    /// Ring buffer of recent tool request summaries for evaluation context.
    private var recentToolRequestSummaries: [String] = []
    private static let maxRecentToolRequests = 10

    /// WARN retry tracking — an identical retry as the very next tool call is auto-approved.
    private var lastWarnedToolName: String?
    private var lastWarnedToolParams: [String: AnyCodable]?

    /// Consecutive parse failures across evaluations. Triggers abort at threshold.
    private var totalConsecutiveFailures = 0
    private static let maxConsecutiveFailures = 20
    private static let maxRetries = 5

    /// Evaluation history for inspector display.
    private var history: [EvaluationRecord] = []
    private static let maxHistory = 50

    public init(
        provider: any LLMProvider,
        systemPrompt: String,
        channel: MessageChannel,
        abort: @escaping @Sendable (String, AgentRole) async -> Void
    ) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.channel = channel
        self.abort = abort
    }

    /// Returns the evaluation history for inspector display.
    public func evaluationHistory() -> [EvaluationRecord] {
        history
    }

    /// Evaluates a tool request and returns a security disposition.
    ///
    /// Posts channel messages for UI visibility (tool review status).
    /// Handles WARN auto-retry: if Brown resubmits an identical request as the very next call,
    /// it is auto-approved without an LLM call.
    public func evaluate(
        toolName: String,
        toolParams: String,
        toolDescription: String,
        toolParameterDefs: String,
        taskTitle: String?,
        taskID: String?,
        taskDescription: String?,
        siblingCalls: String?,
        agentRoleName: String
    ) async -> SecurityDisposition {
        let parsedParams = Self.parseToolParams(toolParams)

        // Auto-approve identical retry of a WARN'd request.
        if let warnedTool = lastWarnedToolName,
           let warnedParams = lastWarnedToolParams,
           warnedTool == toolName,
           parsedParams == warnedParams {
            lastWarnedToolName = nil
            lastWarnedToolParams = nil
            appendSummary("\(toolName) \(toolParams)")
            return SecurityDisposition(approved: true, isAutoApproval: true)
        }
        lastWarnedToolName = nil
        lastWarnedToolParams = nil

        appendSummary("\(toolName) \(toolParams)")

        let evalPrompt = buildEvalPrompt(
            toolName: toolName,
            toolParams: toolParams,
            toolDescription: toolDescription,
            toolParameterDefs: toolParameterDefs,
            taskTitle: taskTitle,
            taskID: taskID,
            taskDescription: taskDescription,
            siblingCalls: siblingCalls
        )

        let messages = [
            LLMMessage(role: .system, text: systemPrompt),
            LLMMessage(role: .user, text: evalPrompt)
        ]

        let startTime = Date()
        var retryCount = 0

        while retryCount < Self.maxRetries {
            let responseText: String
            do {
                let response = try await provider.send(messages: messages, tools: [])
                responseText = response.text ?? ""
            } catch {
                retryCount += 1
                totalConsecutiveFailures += 1

                if totalConsecutiveFailures >= Self.maxConsecutiveFailures {
                    await channel.post(ChannelMessage(
                        sender: .system,
                        content: "Jones produced \(totalConsecutiveFailures) consecutive invalid responses — aborting. Check Jones model configuration."
                    ))
                    await abort(
                        "Jones security gatekeeper failed to produce valid output after \(totalConsecutiveFailures) consecutive attempts",
                        .jones
                    )
                    let disposition = SecurityDisposition(approved: false, message: "Security evaluation aborted due to repeated failures")
                    recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: "LLM error: \(error.localizedDescription)", disposition: disposition, startTime: startTime)
                    return disposition
                }
                continue
            }

            guard let disposition = parseDisposition(responseText, toolName: toolName, parsedParams: parsedParams, agentRoleName: agentRoleName) else {
                retryCount += 1
                totalConsecutiveFailures += 1

                if totalConsecutiveFailures >= Self.maxConsecutiveFailures {
                    await channel.post(ChannelMessage(
                        sender: .system,
                        content: "Jones produced \(totalConsecutiveFailures) consecutive invalid responses — aborting. Check Jones model configuration."
                    ))
                    await abort(
                        "Jones security gatekeeper failed to produce valid output after \(totalConsecutiveFailures) consecutive attempts",
                        .jones
                    )
                    let disposition = SecurityDisposition(approved: false, message: "Security evaluation aborted due to repeated failures")
                    recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: responseText, disposition: disposition, startTime: startTime)
                    return disposition
                }

                // Post error to channel only after several failures.
                if retryCount >= 3 {
                    await channel.post(ChannelMessage(
                        sender: .system,
                        content: "Agent Jones error (\(retryCount)/\(Self.maxRetries)): failed to parse security response",
                        metadata: ["isError": .bool(true), "agentRole": .string(AgentRole.jones.rawValue)]
                    ))
                }
                continue
            }

            totalConsecutiveFailures = 0
            recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: responseText, disposition: disposition, startTime: startTime)

            // Handle ABORT — trigger system-wide shutdown.
            if !disposition.approved, let msg = disposition.message,
               responseText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("ABORT") {
                await channel.post(ChannelMessage(
                    sender: .system,
                    content: "Security review: ABORT — \(msg)",
                    metadata: [
                        "securityDisposition": .string("abort"),
                        "agentRole": .string(AgentRole.jones.rawValue)
                    ]
                ))
                await abort(msg, .jones)
            }

            return disposition
        }

        // Exhausted retries — deny as UNSAFE.
        let fallback = SecurityDisposition(
            approved: false,
            message: "Security evaluation failed after \(Self.maxRetries) attempts"
        )
        recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: "(parse failure)", disposition: fallback, startTime: startTime)
        return fallback
    }

    /// Prunes recent tool summaries when context grows too large.
    public func pruneHistory() {
        guard !recentToolRequestSummaries.isEmpty else { return }
        let removeCount = max(1, recentToolRequestSummaries.count / 2)
        recentToolRequestSummaries.removeFirst(removeCount)
    }

    // MARK: - Private

    private func appendSummary(_ summary: String) {
        recentToolRequestSummaries.append(summary)
        if recentToolRequestSummaries.count > Self.maxRecentToolRequests {
            recentToolRequestSummaries.removeFirst()
        }
    }

    private func recordEvaluation(toolName: String, toolParams: String, taskTitle: String?, prompt: String, response: String, disposition: SecurityDisposition, startTime: Date) {
        let latency = Int(Date().timeIntervalSince(startTime) * 1000)
        let record = EvaluationRecord(
            timestamp: Date(),
            toolName: toolName,
            toolParams: toolParams,
            taskTitle: taskTitle,
            prompt: prompt,
            response: response,
            disposition: disposition,
            latencyMs: latency
        )
        history.append(record)
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
    }

    private func buildEvalPrompt(
        toolName: String,
        toolParams: String,
        toolDescription: String,
        toolParameterDefs: String,
        taskTitle: String?,
        taskID: String?,
        taskDescription: String?,
        siblingCalls: String?
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let dateStr = dateFormatter.string(from: Date())

        var sections: [String] = []
        sections.append("The current date and time are \(dateStr)")

        if let title = taskTitle, let id = taskID {
            sections.append("""
                # Current task
                - title: \(title)
                - identifier: \(id)
                - description: \(taskDescription ?? "")
                """)
        }

        if !recentToolRequestSummaries.isEmpty {
            let recent = recentToolRequestSummaries.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            sections.append("# Recent tool calls (for context):\n\(recent)")
        }

        if let siblings = siblingCalls, !siblings.isEmpty {
            sections.append("""
                # Parallel batch context
                The agent is requesting multiple tool calls simultaneously. \
                The following sibling calls are part of the same batch (for context only — evaluate ONLY the call below):
                \(siblings)
                """)
        }

        var requestSection = """
            # Your task:
            Evaluate the following tool request, in the context of the current task and recent tool calls (above) for data integrity, security and safety:

            ## Tool description
            \(toolDescription)

            ## Tool call to evaluate:
            - tool name: \(toolName)
            - parameters: \(toolParams)

            """
        if !toolParameterDefs.isEmpty {
            requestSection += "\n\(toolParameterDefs)"
        }
        requestSection += """

            # Response
            Plain text response with no markdown, JSON or XML formatting, as one of the following options:

            ## Option 1 -- tool call is safe to run (approved):
            SAFE <brief reasoning why this is safe>

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

        return sections.joined(separator: "\n\n")
    }

    /// Parses Jones's text response into a SecurityDisposition.
    /// Returns nil on parse failure (caller should retry).
    private func parseDisposition(_ text: String, toolName: String, parsedParams: [String: AnyCodable]?, agentRoleName: String) -> SecurityDisposition? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLineEnd = trimmed.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? trimmed.endIndex
        let firstLine = String(trimmed[trimmed.startIndex..<firstLineEnd])
        let words = firstLine.split(separator: " ", maxSplits: 1)

        guard let keyword = words.first else { return nil }
        let keywordUpper = keyword.uppercased()

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

        switch keywordUpper {
        case "SAFE":
            return SecurityDisposition(approved: true, message: explanatoryText)
        case "WARN":
            lastWarnedToolName = toolName
            lastWarnedToolParams = parsedParams
            let warnText = (explanatoryText ?? "") + "\nYour tool was not allowed to execute. Carefully consider the security response text above, in the context of the user's original intent (as given in the task description) and other actions taken and interactions and decide if you really want to call this tool. If you do, send *exactly* the same request again as your *very next* tool call, and it will be approved."
            return SecurityDisposition(approved: false, message: warnText, isWarning: true)
        case "UNSAFE":
            return SecurityDisposition(approved: false, message: explanatoryText)
        case "ABORT":
            return SecurityDisposition(approved: false, message: explanatoryText)
        default:
            return nil
        }
    }

    private static func parseToolParams(_ json: String) -> [String: AnyCodable]? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([String: AnyCodable].self, from: data)
        } catch {
            return nil
        }
    }
}
