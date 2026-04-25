import Foundation
import SwiftLLMKit

/// The outcome of a security evaluation of a tool request.
public struct SecurityDisposition: Sendable {
    public let approved: Bool
    /// Explanation — required when denied, recommended for medium-risk warnings.
    public let message: String?
    /// True when this is a WARN denial — the request can be retried once for auto-approval.
    public let isWarning: Bool
    /// True when this approval was automatic (identical retry of a WARN'd request).
    public let isAutoApproval: Bool

    /// Creates a security disposition with the given approval state and optional metadata.
    public init(approved: Bool, message: String? = nil, isWarning: Bool = false, isAutoApproval: Bool = false) {
        self.approved = approved
        self.message = message
        self.isWarning = isWarning
        self.isAutoApproval = isAutoApproval
    }
}

/// Execution outcome of a tool call.
public enum ToolExecutionOutcome: String, Codable, Sendable {
    /// Tool has not yet been executed
    case notExecuted
    /// Tool was executed and succeeded
    case succeeded
    /// Tool was approved but failed during execution
    case safeButFailed
}

/// Record of a single security evaluation for inspector display.
public struct EvaluationRecord: Sendable, Identifiable {
    public let id = UUID()
    /// When the evaluation occurred.
    public let timestamp: Date
    /// The name of the tool that was evaluated.
    public let toolName: String
    /// The JSON-encoded parameters passed to the tool call.
    public let toolParams: String
    /// The title of the task the tool call was made under, if any.
    public let taskTitle: String?
    /// The full evaluation prompt sent to the Jones LLM.
    public let prompt: String
    /// The raw text response from the Jones LLM.
    public let response: String
    /// The parsed security disposition (approved/denied, warning status, etc.).
    public let disposition: SecurityDisposition
    /// Wall-clock time in milliseconds for the evaluation round-trip.
    public let latencyMs: Int
    /// The execution outcome of the tool call (if executed).
    public let executionOutcome: ToolExecutionOutcome
    /// The tool call ID for tracking execution status.
    public let toolCallID: String
    
    public init(
        timestamp: Date,
        toolName: String,
        toolParams: String,
        taskTitle: String?,
        prompt: String,
        response: String,
        disposition: SecurityDisposition,
        latencyMs: Int,
        executionOutcome: ToolExecutionOutcome = .notExecuted,
        toolCallID: String = ""
    ) {
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolParams = toolParams
        self.taskTitle = taskTitle
        self.prompt = prompt
        self.response = response
        self.disposition = disposition
        self.latencyMs = latencyMs
        self.executionOutcome = executionOutcome
        self.toolCallID = toolCallID
    }
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

    /// Ring buffer of recent tool requests for evaluation context. Each entry
    /// retains the originating tool call ID so the prompt can annotate the
    /// summary with the actual execution outcome (succeeded / failed / unknown)
    /// — without that, Jones sees only "verdict: SAFE" and assumes the tool
    /// actually ran successfully, which leads to false denials of legitimate
    /// retries after a tool error.
    private struct RecentToolRequest {
        let toolName: String
        let toolParams: String
        let verdict: String
        let toolCallID: String?
    }
    private var recentToolRequests: [RecentToolRequest] = []
    private static let maxRecentToolRequests = 10

    /// WARN retry tracking — an identical retry of a WARN'd request is auto-approved.
    /// Uses an array of pending retries instead of a single "last warned" slot so
    /// concurrent evaluations don't clear each other's state.
    private struct WarnedRequest {
        let toolName: String
        let toolParams: [String: AnyCodable]?
    }
    private var pendingWarnRetries: [WarnedRequest] = []
    private static let maxPendingWarnRetries = 10

    /// Consecutive evaluation-level failures (each evaluation exhausted its retries).
    /// Triggers abort at threshold. Only incremented when a full evaluation fails,
    /// not on individual retry attempts — prevents false aborts under concurrency
    /// where transient failures across parallel evaluations would race the counter.
    private var consecutiveEvaluationFailures = 0
    private static let maxConsecutiveFailures = 20
    private static let maxRetries = 5

    /// Tool definition for file_read, presented to Jones's LLM.
    private static let fileReadToolDef: LLMToolDefinition = {
        let tool = FileReadTool()
        return tool.definition(for: .jones)
    }()

    /// Per-call output cap for Jones. A SAFE/WARN/UNSAFE/ABORT verdict line plus
    /// terse reasoning fits comfortably under this. Capping prevents pathological
    /// chain-of-thought preambles from chatty models (notably claude-haiku-4-5)
    /// from running long and burning tokens on output the parser will discard.
    /// Mutually exclusive with extended thinking — Anthropic requires
    /// max_tokens > thinking_budget (>=1024), so enabling thinking on Jones's
    /// configuration would force this cap to be lifted via the override clamp
    /// in the provider.
    private static let evaluationMaxOutputTokens = 200

    /// Evaluation history for inspector display.
    private var history: [EvaluationRecord] = []
    private static let maxHistory = 50

    /// Fires after each evaluation is recorded, pushing the record to the UI layer.
    private var onEvaluationRecorded: (@Sendable (EvaluationRecord) -> Void)?

    /// Token usage store for persistent analytics.
    private let usageStore: UsageStore?
    /// Full snapshot of the ModelConfiguration used for Jones's LLM calls. Carried
    /// directly so UsageRecords get the full config — context size, temperature, etc. —
    /// embedded as immutable historical truth.
    private let configuration: ModelConfiguration?
    /// API type key for the provider (e.g. "anthropic", "openAICompatible"). Not on
    /// ModelConfiguration itself, so still passed separately.
    private let providerType: String
    /// Session ID for the current orchestration run — stamped on every UsageRecord.
    private let sessionID: UUID?

    /// Function to check if a tool call has already succeeded.
    private let hasToolSucceeded: @Sendable (String) async -> Bool
    /// Function to check if a tool call has already failed after being approved.
    private let hasToolFailed: @Sendable (String) async -> Bool

    public init(
        provider: any LLMProvider,
        systemPrompt: String,
        channel: MessageChannel,
        abort: @escaping @Sendable (String, AgentRole) async -> Void,
        usageStore: UsageStore? = nil,
        configuration: ModelConfiguration? = nil,
        providerType: String = "",
        sessionID: UUID? = nil,
        hasToolSucceeded: @escaping @Sendable (String) async -> Bool = { _ in false },
        hasToolFailed: @escaping @Sendable (String) async -> Bool = { _ in false }
    ) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.channel = channel
        self.abort = abort
        self.usageStore = usageStore
        self.configuration = configuration
        self.providerType = providerType
        self.sessionID = sessionID
        self.hasToolSucceeded = hasToolSucceeded
        self.hasToolFailed = hasToolFailed
    }

    /// Returns the evaluation history for inspector display.
    public func evaluationHistory() -> [EvaluationRecord] {
        history
    }

    /// Posts a channel message stamped with the evaluator's provider/model/config
    /// context. Use this instead of `channel.post(...)` for any Jones-originated
    /// message so it carries full provenance for downstream rollups. `taskID`
    /// can be passed explicitly for messages tied to a specific evaluation.
    private func postToChannel(_ message: ChannelMessage, taskID: UUID? = nil) async {
        var stamped = message
        if stamped.taskID == nil { stamped.taskID = taskID }
        if stamped.providerID == nil { stamped.providerID = configuration?.providerID }
        if stamped.modelID == nil { stamped.modelID = configuration?.model }
        if stamped.configuration == nil { stamped.configuration = configuration }
        await channel.post(stamped)
    }

    /// Registers a callback fired after each security evaluation is recorded.
    public func setOnEvaluationRecorded(_ handler: @escaping @Sendable (EvaluationRecord) -> Void) {
        onEvaluationRecorded = handler
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
        agentRoleName: String,
        toolCallID: String? = nil
    ) async -> SecurityDisposition {
        let parsedParams = Self.parseToolParams(toolParams)

        // Auto-approve identical retry of a WARN'd request.
        if let matchIndex = pendingWarnRetries.firstIndex(where: {
            $0.toolName == toolName && $0.toolParams == parsedParams
        }) {
            pendingWarnRetries.remove(at: matchIndex)
            appendSummary(toolName: toolName, toolParams: toolParams, verdict: "SAFE (auto-approved retry of prior WARN)", toolCallID: toolCallID)
            return SecurityDisposition(approved: true, isAutoApproval: true)
        }

        let evalPrompt = await buildEvalPrompt(
            toolName: toolName,
            toolParams: toolParams,
            toolDescription: toolDescription,
            toolParameterDefs: toolParameterDefs,
            taskTitle: taskTitle,
            taskID: taskID,
            taskDescription: taskDescription,
            siblingCalls: siblingCalls
        )

        var conversationMessages = [
            LLMMessage(role: .system, text: systemPrompt),
            LLMMessage(role: .user, text: evalPrompt)
        ]

        let startTime = Date()
        var retryCount = 0
        var lastError: Error?
        // Total iterations includes file read rounds + retries. Prevents unbounded loops
        // if Jones keeps requesting file reads without producing a verdict.
        var totalIterations = 0
        let maxTotalIterations = 25
        while retryCount < Self.maxRetries && totalIterations < maxTotalIterations {
            totalIterations += 1
            let response: LLMResponse
            let callLatencyMs: Int
            do {
                let callStart = Date()
                response = try await provider.send(
                    messages: conversationMessages,
                    tools: [Self.fileReadToolDef],
                    maxOutputTokensOverride: Self.evaluationMaxOutputTokens
                )
                callLatencyMs = Int(Date().timeIntervalSince(callStart) * 1000)
            } catch {
                if Task.isCancelled {
                    let disposition = SecurityDisposition(approved: false, message: "Evaluation cancelled")
                    recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: "(cancelled)", disposition: disposition, startTime: startTime)
                    return disposition
                }
                lastError = error
                retryCount += 1
                continue
            }

            // LLM call succeeded. Execute any file_reads Jones requested, accumulating
            // per-turn tool execution stats for the UsageRecord below.
            var turnToolExecutionMs = 0
            var turnToolResultChars = 0
            if !response.toolCalls.isEmpty {
                // Append assistant message with the tool calls (and any accompanying text).
                if let text = response.text, !text.isEmpty {
                    conversationMessages.append(LLMMessage(role: .assistant, content: .mixed(text: text, toolCalls: response.toolCalls)))
                } else {
                    conversationMessages.append(LLMMessage(role: .assistant, content: .toolCalls(response.toolCalls)))
                }
                // Execute each file_read and append tool results, timing each one.
                for call in response.toolCalls {
                    await postJonesFileReadToChannel(call)
                    let execStart = Date()
                    let result = executeJonesFileRead(call)
                    turnToolExecutionMs += Int(Date().timeIntervalSince(execStart) * 1000)
                    turnToolResultChars += result.count
                    conversationMessages.append(LLMMessage(role: .tool, content: .toolResult(toolCallID: call.id, content: result)))
                }
            }

            // Capture Jones's token usage for analytics — tool stats folded in.
            if let usageStore {
                let taskUUID = taskID.flatMap { UUID(uuidString: $0) }
                await UsageRecorder.record(
                    response: response,
                    context: LLMCallContext(
                        agentRole: .jones,
                        taskID: taskUUID,
                        modelID: configuration?.model ?? "",
                        providerType: providerType,
                        providerID: configuration?.providerID,
                        configuration: configuration,
                        sessionID: sessionID,
                        totalToolExecutionMs: turnToolExecutionMs,
                        totalToolResultChars: turnToolResultChars
                    ),
                    latencyMs: callLatencyMs,
                    to: usageStore
                )
            }

            if !response.toolCalls.isEmpty {
                continue
            }

            let responseText = response.text ?? ""

            guard let disposition = parseDisposition(responseText, toolName: toolName, parsedParams: parsedParams, agentRoleName: agentRoleName) else {
                retryCount += 1

                // Post error to channel only after several failures.
                if retryCount >= 3 {
                    await postToChannel(ChannelMessage(
                        sender: .system,
                        content: "Agent Jones error (\(retryCount)/\(Self.maxRetries)): failed to parse security response",
                        metadata: ["isError": .bool(true), "agentRole": .string(AgentRole.jones.rawValue)]
                    ))
                }
                continue
            }

            consecutiveEvaluationFailures = 0
            recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: responseText, disposition: disposition, startTime: startTime, toolCallID: toolCallID ?? "")

            // Record the summary with the verdict (after evaluation, so we have the result).
            appendSummary(toolName: toolName, toolParams: toolParams, verdict: Self.verdictSummary(from: responseText), toolCallID: toolCallID)

            // Handle ABORT — trigger system-wide shutdown. Uses verdictSummary so
            // ABORT is detected even when the model prefixes the verdict with preamble.
            if !disposition.approved, let msg = disposition.message,
               Self.verdictSummary(from: responseText).uppercased().hasPrefix("ABORT") {
                await postToChannel(ChannelMessage(
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

        // Exhausted retries or iteration limit — this evaluation fully failed.
        consecutiveEvaluationFailures += 1

        let lastErrorDescription = lastError?.localizedDescription

        if consecutiveEvaluationFailures >= Self.maxConsecutiveFailures {
            var abortContent = "Jones produced \(consecutiveEvaluationFailures) consecutive failed evaluations — aborting. Check Jones model configuration."
            if let desc = lastErrorDescription {
                abortContent += "\nLast error: \(desc)"
            }
            await postToChannel(ChannelMessage(
                sender: .system,
                content: abortContent
            ))
            await abort(
                "Jones security gatekeeper failed to produce valid output after \(consecutiveEvaluationFailures) consecutive evaluations",
                .jones
            )
        }

        var fallbackMessage = "Security evaluation failed after \(totalIterations) iterations (\(retryCount) retries)"
        if let desc = lastErrorDescription {
            fallbackMessage += "\nLast error: \(desc)"
        }
        let fallback = SecurityDisposition(
            approved: false,
            message: fallbackMessage
        )
        let recordedResponse = lastErrorDescription ?? "(parse failure)"
        recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: recordedResponse, disposition: fallback, startTime: startTime, toolCallID: toolCallID ?? "")
        appendSummary(toolName: toolName, toolParams: toolParams, verdict: "UNSAFE (evaluation failed)", toolCallID: toolCallID)
        return fallback
    }

    // MARK: - Private

    private func appendSummary(toolName: String, toolParams: String, verdict: String, toolCallID: String?) {
        recentToolRequests.append(RecentToolRequest(
            toolName: toolName,
            toolParams: toolParams,
            verdict: verdict,
            toolCallID: toolCallID
        ))
        if recentToolRequests.count > Self.maxRecentToolRequests {
            recentToolRequests.removeFirst()
        }
    }

    /// Extracts the verdict keyword and reasoning from Jones's raw response text,
    /// stripping the WARN retry boilerplate that is only relevant to Brown.
    ///
    /// Mirrors `parseDisposition`'s preamble-tolerance: scans all lines for the last
    /// one beginning with a verdict keyword so responses with chain-of-thought
    /// preceding the verdict still produce a useful one-line summary.
    private static func verdictSummary(from responseText: String) -> String {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no response)" }
        let verdictKeywords: Set<String> = ["SAFE", "WARN", "UNSAFE", "ABORT"]
        let stripSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`#>-•·\t "))

        var lastVerdictLine: String?
        for rawLine in trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: stripSet)
            guard !line.isEmpty else { continue }
            let words = line.split(separator: " ", maxSplits: 1)
            guard let first = words.first else { continue }
            let keyword = first.trimmingCharacters(in: CharacterSet.punctuationCharacters).uppercased()
            if verdictKeywords.contains(keyword) {
                lastVerdictLine = line
            }
        }

        if let lastVerdictLine { return lastVerdictLine }
        // Fall back to the first non-empty line so summaries still show *something*
        // useful even when the response is unparseable.
        let firstLineEnd = trimmed.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? trimmed.endIndex
        return String(trimmed[trimmed.startIndex..<firstLineEnd])
    }

    private func recordEvaluation(toolName: String, toolParams: String, taskTitle: String?, prompt: String, response: String, disposition: SecurityDisposition, startTime: Date, executionOutcome: ToolExecutionOutcome = .notExecuted, toolCallID: String = "") {
        let latency = Int(Date().timeIntervalSince(startTime) * 1000)
        let record = EvaluationRecord(
            timestamp: Date(),
            toolName: toolName,
            toolParams: toolParams,
            taskTitle: taskTitle,
            prompt: prompt,
            response: response,
            disposition: disposition,
            latencyMs: latency,
            executionOutcome: executionOutcome,
            toolCallID: toolCallID
        )
        history.append(record)
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
        onEvaluationRecorded?(record)
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
    ) async -> String {
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

        if !recentToolRequests.isEmpty {
            // Annotate each entry with the actual execution outcome of the
            // approved tool call. Without this Jones cannot tell that a SAFE
            // verdict still produced an error at execution time, and
            // (incorrectly) refuses legitimate retry attempts as duplicates.
            var renderedLines: [String] = []
            for (index, entry) in recentToolRequests.enumerated() {
                let outcome: String
                if let id = entry.toolCallID, !id.isEmpty {
                    if await hasToolSucceeded(id) {
                        outcome = " [executed: succeeded]"
                    } else if await hasToolFailed(id) {
                        outcome = " [executed: FAILED — retry of an identical request is a legitimate response to the failure, not a duplicate operation]"
                    } else {
                        outcome = " [executed: not yet recorded]"
                    }
                } else {
                    outcome = ""
                }
                renderedLines.append("\(index + 1). \(entry.toolName) \(entry.toolParams) → \(entry.verdict)\(outcome)")
            }
            sections.append("# Recent tool calls (for context):\n\(renderedLines.joined(separator: "\n"))")
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
        // For file-targeting tools, add context about whether the target file exists.
        if toolName == "file_write" || toolName == "file_edit" {
            let pathKey = toolName == "file_edit" ? "file_path" : "path"
            if let fileNote = Self.fileExistenceNote(toolParams: toolParams, pathKey: pathKey, toolName: toolName) {
                requestSection += "\n\(fileNote)\n"
            }
        }

        if !toolParameterDefs.isEmpty {
            requestSection += "\n\(toolParameterDefs)"
        }
        requestSection += """

            # Response
            Plain text response with no markdown, JSON or XML formatting, as one of the following options:

            ## Option 1 -- tool call is safe to run (approved):
            SAFE <brief reasoning why this is safe>

            ## Option 2 -- this tool call or the pattern of recent tool calls appears unsafe to \
            run, but **MIGHT** be okay, *considering the user's stated intent in the task description*:
            WARN <terse message text follows on same line>

            ## Option 3 -- this tool call or the recent pattern of tool calls is unsafe and \
            should not be run:
            UNSAFE <terse text explaining why>

            ## Option 4 -- this tool call or the pattern established by recent history is \
            incredibly unsafe, presenting an immediate danger to the user's data, data \
            integrity, system integrity, the user's health, safety or well-being, or another \
            human's health, safety, or well-being, or is otherwise of a destructive and \
            unwanted nature:
            ABORT <brief terse text explaining why>

            ## If you are uncertain as to how to respond, respond with WARN.

            Your response will be processed by an automated system. DO NOT write any preamble, reasoning, \
            analysis, or chain-of-thought before your verdict. Your response MUST begin — on the very first \
            character of the very first line — with one of the four keywords SAFE, WARN, UNSAFE, or ABORT, \
            followed by your terse reasoning. No leading whitespace, no prefacing sentences, no markdown \
            headers, no "Let me think...", no "Based on...". Just the keyword, then your reasoning, all on one line.

            Correct: `SAFE reading a project file for task context`
            Incorrect: `Let me analyze this... SAFE reading a project file`
            Incorrect: `Based on the task, this appears safe.\\nSAFE reading a project file`
            """
        sections.append(requestSection)

        return sections.joined(separator: "\n\n")
    }

    /// Parses Jones's text response into a SecurityDisposition.
    /// Returns nil on parse failure (caller should retry).
    ///
    /// Robust to models that emit preamble or chain-of-thought before the verdict
    /// (notably observed on claude-haiku-4-5). Scans all lines for the *last* line
    /// whose first word — after trimming leading whitespace, markdown punctuation,
    /// and list bullets — is SAFE/WARN/UNSAFE/ABORT. The last match wins so a model
    /// that reasons about "UNSAFE" earlier and concludes "SAFE" ends up approved.
    private func parseDisposition(_ text: String, toolName: String, parsedParams: [String: AnyCodable]?, agentRoleName: String) -> SecurityDisposition? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdictKeywords: Set<String> = ["SAFE", "WARN", "UNSAFE", "ABORT"]
        let stripSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`#>-•·\t "))

        let lines = trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" })

        var matchedKeyword: String?
        var matchedRemainder: String?
        var matchedLineIndex: Int?

        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine).trimmingCharacters(in: stripSet)
            guard !line.isEmpty else { continue }
            let words = line.split(separator: " ", maxSplits: 1)
            guard let first = words.first else { continue }
            let keywordCandidate = first.trimmingCharacters(in: CharacterSet.punctuationCharacters).uppercased()
            if verdictKeywords.contains(keywordCandidate) {
                matchedKeyword = keywordCandidate
                matchedRemainder = words.count > 1 ? String(words[1]) : nil
                matchedLineIndex = index
            }
        }

        guard let keywordUpper = matchedKeyword, let matchIdx = matchedLineIndex else {
            return nil
        }

        let explanatoryText: String? = {
            var parts: [String] = []
            if let remainder = matchedRemainder, !remainder.isEmpty {
                parts.append(remainder)
            }
            if matchIdx + 1 < lines.count {
                let rest = lines[(matchIdx + 1)...]
                    .map(String.init)
                    .joined(separator: "\n")
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
            pendingWarnRetries.append(WarnedRequest(toolName: toolName, toolParams: parsedParams))
            // Cap the pending retries to prevent unbounded growth.
            if pendingWarnRetries.count > Self.maxPendingWarnRetries {
                pendingWarnRetries.removeFirst()
            }
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

    /// Checks whether the target file of a file_write or file_edit tool call exists,
    /// and returns an informational note string for the evaluation prompt.
    private static func fileExistenceNote(toolParams: String, pathKey: String, toolName: String) -> String? {
        guard let data = toolParams.data(using: .utf8) else {
            return nil
        }

        let parsed: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            parsed = obj
        } catch {
            return nil
        }

        guard let path = parsed[pathKey] as? String,
              path.hasPrefix("/") else {
            return nil
        }

        let fm = FileManager.default
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        if fm.fileExists(atPath: resolvedPath) {
            do {
                let attrs = try fm.attributesOfItem(atPath: resolvedPath)
                let size = (attrs[.size] as? UInt64) ?? 0
                let verb = toolName == "file_edit" ? "MODIFY" : "OVERWRITE"
                return "Note: The target file ALREADY EXISTS (size: \(size) bytes). This operation will \(verb) the existing file."
            } catch {
                return "Note: The target file exists but its attributes could not be read."
            }
        } else {
            return "Note: The target file does NOT currently exist — this is a new file creation."
        }
    }

    /// Posts a tool_request message to the channel so Jones's file reads appear in the transcript.
    private func postJonesFileReadToChannel(_ call: LLMToolCall) async {
        let path: String = {
            guard let data = call.arguments.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
                  case .string(let p) = dict["path"] else {
                return call.arguments
            }
            return p
        }()

        await postToChannel(ChannelMessage(
            sender: .agent(.jones),
            content: "file_read: \(path)",
            metadata: [
                "messageKind": .string("tool_request"),
                "requestID": .string(call.id),
                "tool": .string("file_read"),
                "params": .string(call.arguments),
                "toolDescription": .string(Self.fileReadToolDef.description),
                "toolParameters": .string("")
            ]
        ))
    }

    /// Executes a file_read tool call for Jones without recording the read.
    /// Jones's reads must NOT count toward Brown's file_write gating.
    private func executeJonesFileRead(_ call: LLMToolCall) -> String {
        guard call.name == "file_read" else {
            return "Error: Unknown tool '\(call.name)'"
        }

        let args: [String: AnyCodable]
        do {
            args = try call.parsedArguments()
        } catch {
            return "Error: Invalid arguments — \(error.localizedDescription)"
        }

        guard case .string(let rawPath) = args["path"] else {
            return "Error: Missing required argument 'path'"
        }
        let path = (rawPath as NSString).expandingTildeInPath

        // Use the shared read logic (path restriction, content type detection, line-numbered output).
        return FileReadTool.readFileContent(at: path)
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
