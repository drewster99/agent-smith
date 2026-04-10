import SwiftUI
import AgentSmithKit
import SwiftLLMKit
import UniformTypeIdentifiers
import os

/// Bridges the orchestration runtime to the SwiftUI UI.
@Observable
@MainActor
final class AppViewModel {
    var messages: [ChannelMessage] = []
    var tasks: [AgentTask] = []
    /// Whether the user has restored the persisted history into the transcript.
    var hasRestoredHistory = false
    /// Number of messages loaded from disk at launch (available for restore).
    var persistedHistoryCount = 0
    /// The first task currently awaiting Smith's review, if any. Drives the review banner.
    var taskAwaitingReview: AgentTask? {
        tasks.first { $0.status == .awaitingReview }
    }
    /// Set when a task action (archive, delete) is blocked; drives the error alert.
    var taskActionError: String? = nil
    /// Set when a load/decode operation fails during startup; drives the error alert.
    var startupError: String?
    /// Set to true after `loadPersistedState()` finishes. Drives the startup validation check.
    var hasLoadedPersistedState = false
    /// The user's preferred nickname, shown in the UI and injected into system prompts.
    var nickname: String = ""
    /// Whether to auto-start when all agent configs are valid on launch.
    var autoStartEnabled: Bool = {
        // Default to true if never set
        if UserDefaults.standard.object(forKey: "autoStartEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "autoStartEnabled")
    }() {
        didSet { UserDefaults.standard.set(autoStartEnabled, forKey: "autoStartEnabled") }
    }
    /// Whether Smith automatically runs the next pending task after completing one.
    var autoRunNextTask: Bool = {
        if UserDefaults.standard.object(forKey: "autoRunNextTask") == nil { return true }
        return UserDefaults.standard.bool(forKey: "autoRunNextTask")
    }() {
        didSet {
            UserDefaults.standard.set(autoRunNextTask, forKey: "autoRunNextTask")
            Task { await runtime?.setAutoAdvance(autoRunNextTask) }
        }
    }
    /// Whether interrupted tasks are automatically resumed on launch.
    var autoRunInterruptedTasks: Bool = {
        if UserDefaults.standard.object(forKey: "autoRunInterruptedTasks") == nil { return false }
        return UserDefaults.standard.bool(forKey: "autoRunInterruptedTasks")
    }() {
        didSet { UserDefaults.standard.set(autoRunInterruptedTasks, forKey: "autoRunInterruptedTasks") }
    }
    var isRunning = false
    var isAborted = false
    var abortReason = ""
    var inputText = ""
    var pendingAttachments: [Attachment] = []
    /// History of sent messages for up/down arrow recall.
    private var messageHistory: [String] = []
    /// Current position in message history (-1 = not browsing, 0 = most recent).
    private var historyIndex = -1
    /// Stash of the in-progress text before the user started browsing history.
    private var historyStash = ""
    private static let maxMessageHistory = 100
    /// Roles of agents that are currently waiting for an LLM response.
    var processingRoles: Set<AgentRole> = []
    /// Tools available to each agent role, populated when agents come online.
    var agentToolNames: [AgentRole: [String]] = [:]
    /// Whether the Inspector panel is visible.
    var showInspector = false
    /// Dedicated observable store for inspector data, updated via push callbacks.
    let inspectorStore = AgentInspectorStore()
    /// Current idle poll intervals for each agent role (seconds).
    var agentPollIntervals: [AgentRole: TimeInterval] = [
        .smith: 20, .brown: 25, .jones: 13
    ]
    /// Maximum tool calls per LLM response for each agent role.
    var agentMaxToolCalls: [AgentRole: Int] = [
        .smith: 100, .brown: 100, .jones: 100
    ]
    /// Message debounce intervals for each agent role (seconds).
    var agentMessageDebounceIntervals: [AgentRole: TimeInterval] = [
        .smith: 1, .brown: 1, .jones: 1
    ]

    /// SwiftLLMKit instance managing providers, models, and configurations.
    let llmKit = LLMKitManager(
        appIdentifier: Bundle.main.bundleIdentifier ?? "com.agentsmith",
        keychainServicePrefix: "com.agentsmith.SwiftLLMKit"
    )

    /// Maps each agent role to a `ModelConfiguration.id`.
    var agentAssignments: [AgentRole: UUID] = [:]

    /// All stored memories, refreshed when the memory store changes.
    var storedMemories: [MemoryEntry] = []
    /// All stored task summaries, refreshed when the memory store changes.
    var storedTaskSummaries: [TaskSummaryEntry] = []

    let speechController = SpeechController()

    private let logger = Logger(subsystem: "com.agentsmith", category: "AppViewModel")
    private var runtime: OrchestrationRuntime?
    /// Kept alive independently of `runtime` so task operations work even when agents aren't running.
    private var taskStore: TaskStore?
    private var channelStreamTask: Task<Void, Never>?
    private var persistenceManager: PersistenceManager
    /// Persistent token usage analytics store.
    private(set) var usageStore: UsageStore
    /// Full message history — a superset of `messages`. Never cleared; always written to disk.
    private var allPersistedMessages: [ChannelMessage] = []

    init() {
        let pm = PersistenceManager()
        self.persistenceManager = pm
        self.usageStore = UsageStore(persistence: pm)
    }

    // MARK: - Lifecycle

    /// Loads persisted messages, tasks, and LLM configs from disk. Call on app launch.
    func loadPersistedState() async {
        // Load nickname early so display names and prompts pick it up.
        nickname = UserDefaults.standard.string(forKey: "userNickname") ?? ""
        AgentRole.userNickname = nickname

        // Configure verbose logging for SwiftLLMKit services and providers
        LLMRequestLogger.logDirectoryName = "AgentSmith-LLM-Logs"
        llmKit.verboseLogging = true
        ModelFetchService.verboseLogging = true
        ModelMetadataService.verboseLogging = true

        // Load SwiftLLMKit state (providers, configs, cached models)
        llmKit.load()

        // Load bundled defaults — these provide baseline values for tuning and speech.
        do {
            let bundled = try DefaultsLoader.loadBundledDefaults()
            for (role, tuning) in bundled.agentTuning {
                agentPollIntervals[role] = tuning.pollInterval
                agentMaxToolCalls[role] = tuning.maxToolCalls
                agentMessageDebounceIntervals[role] = tuning.messageDebounceInterval
            }
            speechController.applyBundledDefaults(bundled.speech)

            // Apply bundled provider/config/assignment defaults exactly once on a fresh
            // install. We can't use `llmKit.providers.isEmpty` (built-in providers are
            // seeded on every load) or `llmKit.configurations.isEmpty` (the user might
            // have intentionally deleted all their configs and we'd silently re-create
            // them on next launch). A UserDefaults sentinel is the canonical pattern.
            let didBootstrapKey = "didBootstrapBundledDefaults"
            if !UserDefaults.standard.bool(forKey: didBootstrapKey) {
                for provider in bundled.providers {
                    let apiKey = bundled.providerAPIKeys[provider.id] ?? ""
                    try llmKit.addProvider(provider, apiKey: apiKey)
                }
                for config in bundled.modelConfigurations {
                    llmKit.addConfiguration(config)
                }
                agentAssignments = bundled.agentAssignments
                UserDefaults.standard.set(true, forKey: didBootstrapKey)
            }
        } catch {
            let msg = "No bundled defaults (using hardcoded): \(error)"
            print("[AgentSmith] \(msg)")
            startupError = msg
        }

        // Load persisted message input history
        messageHistory = UserDefaults.standard.stringArray(forKey: "messageHistory") ?? []

        // Load persisted agent assignments
        if let saved = UserDefaults.standard.data(forKey: "agentAssignments") {
            do {
                agentAssignments = try JSONDecoder().decode([AgentRole: UUID].self, from: saved)
            } catch {
                // Migration: before CodingKeyRepresentable conformance, [AgentRole: UUID]
                // was encoded as an alternating array ["smith", "uuid", "brown", "uuid", ...].
                // Try to parse that format and re-save in the new dictionary format.
                do {
                    let array = try JSONDecoder().decode([String].self, from: saved)
                    var migrated: [AgentRole: UUID] = [:]
                    for i in stride(from: 0, to: array.count - 1, by: 2) {
                        if let role = AgentRole(rawValue: array[i]),
                           let uuid = UUID(uuidString: array[i + 1]) {
                            migrated[role] = uuid
                        }
                    }
                    agentAssignments = migrated
                    print("[AgentSmith] Migrated agent assignments from legacy array format")
                    persistAgentAssignments()
                } catch {
                    let msg = "Failed to decode agent assignments: \(error)"
                    print("[AgentSmith] \(msg)")
                    startupError = msg
                }
            }
        }

        // Prune stale assignments that reference configurations that no longer exist.
        let validConfigIDs = Set(llmKit.configurations.map(\.id))
        for (role, configID) in agentAssignments {
            if !validConfigIDs.contains(configID) {
                agentAssignments[role] = nil
                print("[AgentSmith] Cleared stale agent assignment for \(role.rawValue) → \(configID)")
            }
        }

        do {
            var savedMessages = try await persistenceManager.loadChannelLog()
            // One-time migration: strip `fileWriteOldContent` and `fileWriteContent`
            // metadata from historical tool_request rows. Prior versions of
            // AgentActor.postToolRequestToChannel captured the full pre- and
            // post-write file contents into channel metadata for the inline diff
            // view. We now precompute the diff and store only the resulting
            // `[DiffLine]` array in `fileWriteDiff` — so the old raw content is
            // dead weight inflating channel_log.json. Strip it here so the file
            // shrinks on the next save. Idempotent: if no stale keys are found,
            // nothing is re-saved.
            var strippedCount = 0
            for i in savedMessages.indices {
                guard var md = savedMessages[i].metadata else { continue }
                var changed = false
                if md.removeValue(forKey: "fileWriteOldContent") != nil { changed = true }
                if md.removeValue(forKey: "fileWriteContent") != nil { changed = true }
                if changed {
                    savedMessages[i].metadata = md
                    strippedCount += 1
                }
            }
            // Re-save inline (not via a detached task) BEFORE assigning the loaded
            // array to `allPersistedMessages`. The alternative — firing the save
            // via Task.detached — races with any subsequent `persistMessages()`
            // that might append a new message after load: PersistenceManager is
            // an actor so both saves serialize, but actor enqueue order isn't
            // guaranteed to match the caller-side scheduling order, so the
            // migration write could clobber a newer write. Awaiting here means
            // anything posted after load is guaranteed to see the migrated
            // baseline and save on top of it.
            if strippedCount > 0 {
                print("[AgentSmith] Stripped stale file_write diff metadata from \(strippedCount) message(s); re-saving channel log.")
                do {
                    try await persistenceManager.saveChannelLog(savedMessages)
                } catch {
                    logger.error("Failed to re-save channel log after migration: \(error)")
                }
            }
            allPersistedMessages = savedMessages
            persistedHistoryCount = savedMessages.count
        } catch {
            let msg = "Failed to load channel log: \(error)"
            print("[AgentSmith] \(msg)")
            startupError = msg
        }

        do {
            var savedTasks = try await persistenceManager.loadTasks()
            // Mark any tasks that were running when the app last exited as interrupted.
            // The runtime handles auto-resuming interrupted tasks if that setting is enabled.
            var anyStatusChanged = false
            for i in savedTasks.indices {
                if savedTasks[i].status == .running {
                    savedTasks[i].status = .interrupted
                    savedTasks[i].updatedAt = Date()
                    anyStatusChanged = true
                }
            }
            // Archive any completed tasks that have been sitting for more than 4 hours.
            let cutoff = Date().addingTimeInterval(-4 * 3600)
            var anyArchived = false
            for i in savedTasks.indices {
                if savedTasks[i].status == .completed,
                   savedTasks[i].disposition == .active,
                   savedTasks[i].updatedAt < cutoff {
                    savedTasks[i].disposition = .archived
                    anyArchived = true
                }
            }
            tasks = savedTasks
            if anyArchived || anyStatusChanged { persistTasks() }

            // Populate a standalone task store immediately so task operations (archive, delete, etc.)
            // work even before the user starts the runtime. start() will replace this with the
            // runtime's store once the system is running.
            let standaloneStore = TaskStore()
            taskStore = standaloneStore
            await standaloneStore.restore(savedTasks)
            await standaloneStore.setOnChange { [weak self, weak standaloneStore] in
                Task { @MainActor [weak self, weak standaloneStore] in
                    guard let self, let store = standaloneStore else { return }
                    let allTasks = await store.allTasks()
                    self.tasks = allTasks
                    self.persistTasks()
                }
            }
        } catch {
            let msg = "Failed to load tasks: \(error)"
            print("[AgentSmith] \(msg)")
            startupError = msg
        }

        // TODO: Remove migration after May 9 2026
        // One-time migration: backfill `providerID` AND the full `configuration` snapshot
        // on usage records persisted before those fields existed. For each record missing
        // either, look up the originating ModelConfiguration via configurationID and copy
        // the full config in — but ONLY if the config's current providerType still matches
        // the record's providerType. If the user has since repointed the config at a
        // different provider family, we leave the record unchanged rather than write wrong
        // attribution. Records whose config or provider has been deleted, or whose
        // configurationID was never captured, are also left unchanged. Idempotent: once
        // a record has providerID AND configuration populated it's skipped on the next
        // pass; the save below is gated on `backfilled > 0`.
        do {
            var rawRecords = try await persistenceManager.loadUsageRecords()
            var backfilled = 0
            var alreadyComplete = 0
            var noConfigurationID = 0
            var configMissing = 0
            var providerMissing = 0
            var providerTypeMismatch = 0
            for i in rawRecords.indices {
                let record = rawRecords[i]
                if record.providerID != nil && record.configuration != nil {
                    alreadyComplete += 1
                    continue
                }
                guard let configID = record.configurationID else {
                    noConfigurationID += 1
                    continue
                }
                guard let config = llmKit.configurations.first(where: { $0.id == configID }) else {
                    configMissing += 1
                    continue
                }
                guard let provider = llmKit.providers.first(where: { $0.id == config.providerID }) else {
                    providerMissing += 1
                    continue
                }
                guard provider.apiType.rawValue == record.providerType else {
                    providerTypeMismatch += 1
                    continue
                }
                rawRecords[i] = UsageRecord(
                    id: record.id,
                    timestamp: record.timestamp,
                    agentRole: record.agentRole,
                    taskID: record.taskID,
                    modelID: record.modelID,
                    providerType: record.providerType,
                    providerID: config.providerID,
                    configuration: config,
                    configurationID: configID,
                    inputTokens: record.inputTokens,
                    outputTokens: record.outputTokens,
                    cacheReadTokens: record.cacheReadTokens,
                    cacheWriteTokens: record.cacheWriteTokens,
                    latencyMs: record.latencyMs,
                    preResetInputTokens: record.preResetInputTokens,
                    outputCharCount: record.outputCharCount,
                    toolCallCount: record.toolCallCount,
                    toolCallNames: record.toolCallNames,
                    toolCallArgumentsChars: record.toolCallArgumentsChars,
                    totalToolExecutionMs: record.totalToolExecutionMs,
                    totalToolResultChars: record.totalToolResultChars,
                    sessionID: record.sessionID
                )
                backfilled += 1
            }
            let totalRecords = rawRecords.count
            let unrecoverable = noConfigurationID + configMissing + providerMissing + providerTypeMismatch
            print("[AgentSmith] UsageRecord configuration migration: total=\(totalRecords), alreadyComplete=\(alreadyComplete), backfilled=\(backfilled), unrecoverable=\(unrecoverable) (configMissing=\(configMissing), providerMissing=\(providerMissing), providerTypeMismatch=\(providerTypeMismatch), noConfigurationID=\(noConfigurationID))")
            if backfilled > 0 {
                do {
                    try await persistenceManager.saveUsageRecords(rawRecords)
                    print("[AgentSmith] UsageRecord configuration migration: re-saved usage_records.json with \(backfilled) backfilled records.")
                } catch {
                    logger.error("Failed to save migrated usage records: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Failed to load usage records for configuration migration: \(error.localizedDescription)")
        }

        // TODO: Remove migration after 05/10/2026
        // One-time migration: backfill taskID on Smith's UsageRecords. Smith
        // orchestrates every task but was never listed in assigneeIDs, so
        // taskForAgent returned nil and all Smith records got taskID = nil.
        // Fix: match each Smith record's timestamp to the task that was active
        // (running or awaitingReview) at that time using startedAt/completedAt
        // windows. Idempotent: records with non-nil taskID are skipped.
        do {
            var rawRecords = try await persistenceManager.loadUsageRecords()
            let smithNeedsBackfill = rawRecords.contains { $0.agentRole == .smith && $0.taskID == nil }
            if smithNeedsBackfill {
                // Build time windows from tasks: (taskID, start, end)
                struct TaskWindow {
                    let taskID: UUID
                    let start: Date
                    let end: Date
                }
                var windows: [TaskWindow] = []
                for task in tasks {
                    guard let started = task.startedAt else { continue }
                    let ended = task.completedAt ?? task.updatedAt
                    windows.append(TaskWindow(taskID: task.id, start: started, end: ended))
                }
                windows.sort { $0.start < $1.start }

                var backfilled = 0
                var alreadyHadTaskID = 0
                var noMatch = 0
                var notSmith = 0

                for i in rawRecords.indices {
                    let record = rawRecords[i]
                    guard record.agentRole == .smith else { notSmith += 1; continue }
                    guard record.taskID == nil else { alreadyHadTaskID += 1; continue }

                    // Find a task window that contains this timestamp
                    let ts = record.timestamp
                    if let match = windows.last(where: { ts >= $0.start && ts <= $0.end }) {
                        rawRecords[i] = UsageRecord(
                            id: record.id,
                            timestamp: record.timestamp,
                            agentRole: record.agentRole,
                            taskID: match.taskID,
                            modelID: record.modelID,
                            providerType: record.providerType,
                            providerID: record.providerID,
                            configuration: record.configuration,
                            configurationID: record.configurationID,
                            inputTokens: record.inputTokens,
                            outputTokens: record.outputTokens,
                            cacheReadTokens: record.cacheReadTokens,
                            cacheWriteTokens: record.cacheWriteTokens,
                            latencyMs: record.latencyMs,
                            preResetInputTokens: record.preResetInputTokens,
                            outputCharCount: record.outputCharCount,
                            toolCallCount: record.toolCallCount,
                            toolCallNames: record.toolCallNames,
                            toolCallArgumentsChars: record.toolCallArgumentsChars,
                            totalToolExecutionMs: record.totalToolExecutionMs,
                            totalToolResultChars: record.totalToolResultChars,
                            sessionID: record.sessionID
                        )
                        backfilled += 1
                    } else {
                        noMatch += 1
                    }
                }

                let smithTotal = backfilled + alreadyHadTaskID + noMatch
                let pct: (Int) -> String = { n in
                    guard smithTotal > 0 else { return "0.0%" }
                    return String(format: "%.1f%%", Double(n) / Double(smithTotal) * 100)
                }
                print("[AgentSmith] Smith taskID backfill: smithRecords=\(smithTotal), backfilled=\(backfilled) (\(pct(backfilled))), alreadyHadTaskID=\(alreadyHadTaskID), noMatch=\(noMatch) (\(pct(noMatch)))")

                if backfilled > 0 {
                    do {
                        try await persistenceManager.saveUsageRecords(rawRecords)
                        print("[AgentSmith] Smith taskID backfill: saved \(backfilled) updated records.")
                    } catch {
                        logger.error("Failed to save Smith taskID backfill: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            logger.error("Failed to load usage records for Smith taskID backfill: \(error.localizedDescription)")
        }

        // TODO: Remove migration after 05/10/2026
        // One-time migration: backfill toolCallNames/toolCallCount on usage records
        // from the raw API response log files in $TMPDIR/AgentSmith-LLM-Logs/.
        // These fields were only captured starting in Phase 1; older records have nil.
        // The migration matches each record to its nearest response log by timestamp
        // (within 10 seconds) and extracts tool call names from the JSON. Idempotent:
        // records with non-nil toolCallNames are skipped. If the log directory doesn't
        // exist (cleaned up by the OS), the migration is a no-op.
        do {
            var rawRecords = try await persistenceManager.loadUsageRecords()
            let needsBackfill = rawRecords.contains { $0.toolCallNames == nil }

            if needsBackfill {
                let logDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AgentSmith-LLM-Logs")
                let fm = FileManager.default
                if !fm.fileExists(atPath: logDir.path) {
                    print("[AgentSmith] Tool call backfill: log directory not found at \(logDir.path); skipping.")
                } else {

                // Index response logs by modification time for fast lookup.
                let logFiles = (try? fm.contentsOfDirectory(
                    at: logDir, includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? []
                let responseFiles = logFiles.filter { $0.lastPathComponent.hasSuffix("_response.json") }

                struct LogEntry {
                    let mtime: TimeInterval
                    let toolNames: [String]
                }
                var logEntries: [LogEntry] = []
                for file in responseFiles {
                    guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                          let mdate = attrs[.modificationDate] as? Date else { continue }
                    guard let data = try? Data(contentsOf: file),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    var names: [String] = []
                    // OpenAI / Mistral
                    if let choices = json["choices"] as? [[String: Any]] {
                        for choice in choices {
                            for tc in ((choice["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]]) ?? [] {
                                if let name = (tc["function"] as? [String: Any])?["name"] as? String {
                                    names.append(name)
                                }
                            }
                        }
                    // Anthropic
                    } else if let content = json["content"] as? [[String: Any]] {
                        for block in content where block["type"] as? String == "tool_use" {
                            if let name = block["name"] as? String { names.append(name) }
                        }
                    // Gemini
                    } else if let candidates = json["candidates"] as? [[String: Any]] {
                        for cand in candidates {
                            for part in ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
                                if let fc = part["functionCall"] as? [String: Any],
                                   let name = fc["name"] as? String {
                                    names.append(name)
                                }
                            }
                        }
                    }
                    logEntries.append(LogEntry(mtime: mdate.timeIntervalSinceReferenceDate, toolNames: names))
                }
                logEntries.sort { $0.mtime < $1.mtime }
                let logMtimes = logEntries.map(\.mtime)

                print("[AgentSmith] Tool call backfill: indexed \(logEntries.count) response logs.")

                let matchWindow: TimeInterval = 10
                var backfilled = 0
                var alreadyPopulated = 0
                var noMatch = 0

                for i in rawRecords.indices {
                    if rawRecords[i].toolCallNames != nil {
                        alreadyPopulated += 1
                        continue
                    }
                    let ts = rawRecords[i].timestamp.timeIntervalSinceReferenceDate
                    // Binary search for nearest entry within the match window.
                    var lo = logMtimes.startIndex
                    var hi = logMtimes.endIndex
                    while lo < hi {
                        let mid = lo + (hi - lo) / 2
                        if logMtimes[mid] < ts - matchWindow { lo = mid + 1 } else { hi = mid }
                    }
                    var bestDist = TimeInterval.infinity
                    var bestIdx = -1
                    var idx = lo
                    while idx < logEntries.count {
                        let entryTime = logEntries[idx].mtime
                        if entryTime > ts + matchWindow { break }
                        let dist = abs(entryTime - ts)
                        if dist < bestDist { bestDist = dist; bestIdx = idx }
                        idx += 1
                    }
                    guard bestIdx >= 0 else { noMatch += 1; continue }

                    let matched = logEntries[bestIdx]
                    rawRecords[i] = UsageRecord(
                        id: rawRecords[i].id,
                        timestamp: rawRecords[i].timestamp,
                        agentRole: rawRecords[i].agentRole,
                        taskID: rawRecords[i].taskID,
                        modelID: rawRecords[i].modelID,
                        providerType: rawRecords[i].providerType,
                        providerID: rawRecords[i].providerID,
                        configuration: rawRecords[i].configuration,
                        configurationID: rawRecords[i].configurationID,
                        inputTokens: rawRecords[i].inputTokens,
                        outputTokens: rawRecords[i].outputTokens,
                        cacheReadTokens: rawRecords[i].cacheReadTokens,
                        cacheWriteTokens: rawRecords[i].cacheWriteTokens,
                        latencyMs: rawRecords[i].latencyMs,
                        preResetInputTokens: rawRecords[i].preResetInputTokens,
                        outputCharCount: rawRecords[i].outputCharCount,
                        toolCallCount: matched.toolNames.count,
                        toolCallNames: matched.toolNames,
                        toolCallArgumentsChars: rawRecords[i].toolCallArgumentsChars,
                        totalToolExecutionMs: rawRecords[i].totalToolExecutionMs,
                        totalToolResultChars: rawRecords[i].totalToolResultChars,
                        sessionID: rawRecords[i].sessionID
                    )
                    backfilled += 1
                }

                let total = rawRecords.count
                let pct: (Int) -> String = { n in
                    guard total > 0 else { return "0.0%" }
                    return String(format: "%.1f%%", Double(n) / Double(total) * 100)
                }
                print("[AgentSmith] Tool call backfill: total=\(total), backfilled=\(backfilled) (\(pct(backfilled))), alreadyPopulated=\(alreadyPopulated) (\(pct(alreadyPopulated))), noMatch=\(noMatch) (\(pct(noMatch)))")

                if backfilled > 0 {
                    do {
                        try await persistenceManager.saveUsageRecords(rawRecords)
                        print("[AgentSmith] Tool call backfill: saved \(backfilled) updated records.")
                    } catch {
                        logger.error("Failed to save tool call backfill: \(error.localizedDescription)")
                    }
                }
                } // else (log directory exists)
            }
        } catch {
            logger.error("Failed to load usage records for tool call backfill: \(error.localizedDescription)")
        }

        // Load persisted usage records.
        await usageStore.load()

        // TODO: Remove migration after 05/10/2026
        // One-time migration: backfill ChannelMessage context (taskID, sessionID,
        // providerID, modelID, configuration) on historical messages persisted
        // before those fields existed. For each message with no context stamped,
        // find the nearest UsageRecord within a 10-second window whose agentRole
        // matches the message's sender (or recipient for user-to-agent messages)
        // and inherit its context. Reports coverage stats in four buckets:
        //   - backfilled: a matching UsageRecord was found and its context copied
        //   - alreadyStamped: at least one context field was already populated
        //   - unmatched: had no context, expected an agent, no record within 10s
        //   - notJoinable: no way to determine agent context (pure system messages,
        //                  broadcast user messages with no agent recipient)
        // Idempotent: messages with alreadyStamped context are skipped on re-run.
        do {
            let usageRecords = await usageStore.allRecords()
            // Sort records by timestamp once for early-exit when scanning.
            // Records are typically already in append order, but we sort defensively.
            let sortedRecords = usageRecords.sorted { $0.timestamp < $1.timestamp }

            var savedMessages = allPersistedMessages
            var backfilled = 0
            var alreadyStamped = 0
            var unmatched = 0
            var notJoinable = 0
            let joinWindowSeconds: TimeInterval = 10

            for i in savedMessages.indices {
                let m = savedMessages[i]

                // Skip if any context field is already populated (idempotent re-runs).
                let hasAnyContext = m.taskID != nil
                    || m.sessionID != nil
                    || m.providerID != nil
                    || m.modelID != nil
                    || m.configuration != nil
                if hasAnyContext {
                    alreadyStamped += 1
                    continue
                }

                // Determine which agent role's UsageRecord we should match against.
                let expectedRole: AgentRole?
                switch m.sender {
                case .agent(let role):
                    expectedRole = role
                case .user:
                    if case .agent(let role) = m.recipient {
                        expectedRole = role
                    } else {
                        // Broadcast user messages with no agent recipient can't be
                        // unambiguously attributed to a single agent. Skip the join.
                        notJoinable += 1
                        continue
                    }
                case .system:
                    // System messages don't carry agent-scoped context by design.
                    notJoinable += 1
                    continue
                }

                let lowerBound = m.timestamp.addingTimeInterval(-joinWindowSeconds)
                let upperBound = m.timestamp.addingTimeInterval(joinWindowSeconds)
                var bestRecord: UsageRecord?
                var bestDistance = TimeInterval.infinity
                // Scan is O(n) over the filtered window; acceptable for the
                // one-shot startup pass even with tens of thousands of records.
                for record in sortedRecords {
                    if record.timestamp < lowerBound { continue }
                    if record.timestamp > upperBound { break }
                    if let expected = expectedRole, record.agentRole != expected {
                        continue
                    }
                    let dist = abs(record.timestamp.timeIntervalSince(m.timestamp))
                    if dist < bestDistance {
                        bestDistance = dist
                        bestRecord = record
                    }
                }

                guard let match = bestRecord else {
                    unmatched += 1
                    continue
                }

                savedMessages[i].taskID = match.taskID
                savedMessages[i].sessionID = match.sessionID
                savedMessages[i].providerID = match.providerID
                savedMessages[i].modelID = match.modelID
                savedMessages[i].configuration = match.configuration
                backfilled += 1
            }

            let total = savedMessages.count
            let pct: (Int) -> String = { n in
                guard total > 0 else { return "0.0%" }
                return String(format: "%.1f%%", Double(n) / Double(total) * 100)
            }
            print("[AgentSmith] ChannelMessage context migration: total=\(total), backfilled=\(backfilled) (\(pct(backfilled))), alreadyStamped=\(alreadyStamped) (\(pct(alreadyStamped))), unmatched=\(unmatched) (\(pct(unmatched))), notJoinable=\(notJoinable) (\(pct(notJoinable)))")

            if backfilled > 0 {
                do {
                    try await persistenceManager.saveChannelLog(savedMessages)
                    allPersistedMessages = savedMessages
                    print("[AgentSmith] ChannelMessage context migration: re-saved channel_log.json with \(backfilled) backfilled messages (\(pct(backfilled)) of total).")
                } catch {
                    logger.error("Failed to save migrated channel log: \(error.localizedDescription)")
                }
            }
        }

        // Load user model metadata overrides and inject into LLMKitManager.
        do {
            let overrides = try await persistenceManager.loadUserModelOverrides()
            if !overrides.isEmpty {
                llmKit.setUserOverrides(overrides)
            }
        } catch {
            logger.error("Failed to load user model overrides: \(error.localizedDescription)")
        }

        // Refresh model catalog (YYYYMMDD-gated)
        await llmKit.refreshIfNeeded()
        llmKit.validateConfigurations()

        hasLoadedPersistedState = true
    }

    /// Starts the system with current LLM configs.
    func start() async {
        guard !isRunning else { return }
        guard !isAborted else { return }

        // Validate that all required roles have assignments before starting.
        let missingRoles = AgentRole.requiredRoles.filter { agentAssignments[$0] == nil }
        if !missingRoles.isEmpty {
            let names = missingRoles.map(\.displayName).joined(separator: ", ")
            startupError = "Cannot start — missing configuration for: \(names)"
            return
        }

        // Resolve agent assignments into providers and configurations.
        var providers: [AgentRole: any LLMProvider] = [:]
        var configurations: [AgentRole: ModelConfiguration] = [:]
        var apiTypes: [AgentRole: ProviderAPIType] = [:]
        for role in AgentRole.allCases {
            guard let configID = agentAssignments[role] else { continue }
            do {
                providers[role] = try llmKit.makeProvider(for: configID)
            } catch {
                startupError = "Failed to create provider for \(role.displayName): \(error.localizedDescription)"
                return
            }
            if let modelConfig = llmKit.configurations.first(where: { $0.id == configID }) {
                configurations[role] = modelConfig
                if let modelProvider = llmKit.providers.first(where: { $0.id == modelConfig.providerID }) {
                    apiTypes[role] = modelProvider.apiType
                }
            }
        }

        var tuning: [AgentRole: AgentTuningConfig] = [:]
        for role in AgentRole.allCases {
            tuning[role] = AgentTuningConfig(
                pollInterval: agentPollIntervals[role] ?? 5,
                maxToolCalls: agentMaxToolCalls[role] ?? 100,
                messageDebounceInterval: agentMessageDebounceIntervals[role] ?? 1
            )
        }

        let embeddingService: EmbeddingService
        do {
            embeddingService = try EmbeddingService()
        } catch {
            let msg = "Failed to initialize embedding service: \(error.localizedDescription)"
            print("[AgentSmith] \(msg)")
            startupError = msg
            return
        }

        let newRuntime = OrchestrationRuntime(
            providers: providers,
            configurations: configurations,
            providerAPITypes: apiTypes,
            agentTuning: tuning,
            embeddingService: embeddingService,
            usageStore: usageStore,
            autoAdvanceEnabled: autoRunNextTask,
            autoRunInterruptedTasks: autoRunInterruptedTasks
        )
        runtime = newRuntime
        isRunning = true

        // Restore persisted tasks into the runtime's task store
        if !tasks.isEmpty {
            let tasksToRestore = tasks
            await newRuntime.taskStore.restore(tasksToRestore)
        }

        // Register abort callback
        await newRuntime.setOnAbort { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAborted = true
                self.abortReason = reason
                self.isRunning = false
                self.processingRoles.removeAll()
                self.agentToolNames.removeAll()
                self.inspectorStore.clearAll()
                self.runtime = nil
            }
        }

        // Track which agents are actively waiting for an LLM response
        await newRuntime.setOnProcessingStateChange { [weak self] role, isProcessing in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isProcessing {
                    self.processingRoles.insert(role)
                } else {
                    self.processingRoles.remove(role)
                }
            }
        }

        // Capture tool names from each agent when it comes online
        await newRuntime.setOnAgentStarted { [weak self] role, toolNames in
            Task { @MainActor [weak self] in
                self?.agentToolNames[role] = toolNames
            }
        }

        // Subscribe to channel messages
        let channel = await newRuntime.channel
        channelStreamTask = Task { @MainActor [weak self] in
            for await message in await channel.stream() {
                guard let self else { break }
                self.messages.append(message)
                self.allPersistedMessages.append(message)
                self.speechController.handle(message)
                self.persistMessages()
            }
        }

        // Subscribe to task changes — keep a strong reference so operations work post-stop
        let taskStore = await newRuntime.taskStore
        self.taskStore = taskStore
        await taskStore.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allTasks = await taskStore.allTasks()
                self.tasks = allTasks
                self.persistTasks()
            }
        }

        // Archive any completed tasks older than 4 hours now that the store is live.
        await taskStore.archiveStaleCompleted()

        // Restore persisted memories and task summaries into the memory store.
        let memoryStore = await newRuntime.memoryStore
        do {
            let savedMemories = try await persistenceManager.loadMemories()
            let savedTaskSummaries = try await persistenceManager.loadTaskSummaries()
            if !savedMemories.isEmpty || !savedTaskSummaries.isEmpty {
                await memoryStore.restore(memories: savedMemories, taskSummaries: savedTaskSummaries)

                // Re-embed all memories and task summaries with multi-sentence
                // Double-precision vectors. Measures and logs wall-clock time.
                let reembedStart = Date()

                let memCount = try await memoryStore.reembedAllMemories()

                let allTasks = await taskStore.allTasks()
                let taskCount = try await memoryStore.reembedTaskSummariesFromTasks(allTasks)

                let reembedMs = Int(Date().timeIntervalSince(reembedStart) * 1000)
                if memCount > 0 || taskCount > 0 {
                    print("[AgentSmith] Re-embedded \(memCount) memories, \(taskCount) task summaries in \(reembedMs)ms")
                }
            }
        } catch {
            print("[AgentSmith] Failed to load/re-embed memories: \(error)")
        }

        // Wire memory persistence and UI refresh — save to disk and update published
        // arrays whenever memories change.
        await memoryStore.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.persistMemories(memoryStore: memoryStore)
                await self.refreshMemories()
            }
        }

        // Initial population of the memory arrays for the UI.
        await refreshMemories()

        // Push LLM turn records from agents into the inspector store incrementally.
        await newRuntime.setOnTurnRecorded { [weak self] role, turn in
            Task { @MainActor [weak self] in
                self?.inspectorStore.appendTurn(turn, for: role)
            }
        }

        // Push live conversation history from agents into the inspector store.
        await newRuntime.setOnContextChanged { [weak self] role, messages in
            Task { @MainActor [weak self] in
                self?.inspectorStore.updateLiveContext(messages, for: role)
            }
        }

        // Push security evaluation records into the inspector store incrementally.
        await newRuntime.setOnEvaluationRecorded { [weak self] record in
            Task { @MainActor [weak self] in
                self?.inspectorStore.appendEvaluation(record)
            }
        }

        await newRuntime.start()
    }

    /// Sends user input (with any pending attachments) to Smith.
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        // Handle slash commands locally before sending to the runtime.
        if pendingAttachments.isEmpty, text.lowercased() == "/clear" {
            inputText = ""
            clearLog()
            return
        }

        guard let runtime else { return }

        let attachments = pendingAttachments
        inputText = ""
        pendingAttachments = []

        // Record non-empty text in message history for up/down arrow recall.
        if !text.isEmpty {
            // Remove duplicate if the same message was sent most recently.
            if messageHistory.last != text {
                messageHistory.append(text)
            }
            if messageHistory.count > Self.maxMessageHistory {
                messageHistory.removeFirst(messageHistory.count - Self.maxMessageHistory)
            }
            historyIndex = -1
            historyStash = ""
            UserDefaults.standard.set(messageHistory, forKey: "messageHistory")
        }

        // Save attachment files to disk
        for attachment in attachments {
            Task.detached { [persistenceManager, logger] in
                do {
                    try await persistenceManager.saveAttachment(attachment)
                } catch {
                    logger.error("Failed to save attachment \(attachment.filename): \(error)")
                }
            }
        }

        await runtime.sendUserMessage(text, attachments: attachments)
    }

    /// Navigates through message history. Call with `.up` to recall older messages, `.down` for newer.
    enum HistoryDirection { case up, down }

    @discardableResult
    func navigateHistory(_ direction: HistoryDirection) -> Bool {
        guard !messageHistory.isEmpty else { return false }

        switch direction {
        case .up:
            if historyIndex == -1 {
                // Entering history mode — stash whatever the user was typing.
                historyStash = inputText
                historyIndex = messageHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            } else {
                return false // already at oldest
            }
            inputText = messageHistory[historyIndex]
            return true

        case .down:
            guard historyIndex >= 0 else { return false } // not in history mode
            if historyIndex < messageHistory.count - 1 {
                historyIndex += 1
                inputText = messageHistory[historyIndex]
            } else {
                // Past the newest — restore the stash and exit history mode.
                historyIndex = -1
                inputText = historyStash
                historyStash = ""
            }
            return true
        }
    }

    /// Sends a private message from the user directly to the specified agent role.
    func sendDirectMessage(to role: AgentRole, text: String) async {
        guard let runtime else { return }
        await runtime.sendDirectMessage(to: role, text: text)
    }

    /// Replaces the system prompt for the active agent with the given role.
    func updateSystemPrompt(for role: AgentRole, prompt: String) async {
        guard let runtime else { return }
        await runtime.updateSystemPrompt(for: role, prompt: prompt)
    }

    // MARK: - Task actions

    func archiveTask(id: UUID) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.archive(id: id)
        if !succeeded {
            taskActionError = "This task is in progress and cannot be archived."
        }
    }

    func deleteTask(id: UUID) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.softDelete(id: id)
        if !succeeded {
            taskActionError = "This task is in progress and cannot be deleted."
        }
    }

    func unarchiveTask(id: UUID) async {
        await taskStore?.unarchive(id: id)
    }

    func undeleteTask(id: UUID) async {
        await taskStore?.undelete(id: id)
    }

    func permanentlyDeleteTask(id: UUID) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.permanentlyDelete(id: id)
        if !succeeded {
            taskActionError = "This task is in progress and cannot be permanently deleted."
        }
    }

    func updateTaskDescription(id: UUID, description: String) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.updateDescription(id: id, description: description)
        if !succeeded {
            taskActionError = "Only pending, paused, or interrupted tasks can be edited."
        }
    }

    func pauseTask(id: UUID) async {
        await runtime?.terminateTaskAgents(taskID: id)
        await taskStore?.pause(id: id)
    }

    func stopTask(id: UUID) async {
        await runtime?.terminateTaskAgents(taskID: id)
        await taskStore?.stop(id: id)
    }

    /// Soft-deletes the failed task (a new one will be created on retry) and asks Smith to retry.
    func retryTask(_ task: AgentTask) async {
        await taskStore?.softDelete(id: task.id)
        await sendDirectMessage(
            to: .smith,
            text: "Please retry this failed task:\nTitle: \(task.title)\nDescription: \(task.description)\nID: \(task.id.uuidString)"
        )
    }

    /// Archives the completed task (a new one will be created) and asks Smith to run it again.
    func runTaskAgain(_ task: AgentTask) async {
        await taskStore?.archive(id: task.id)
        await sendDirectMessage(
            to: .smith,
            text: "Please run this task again:\nTitle: \(task.title)\nDescription: \(task.description)\nID: \(task.id.uuidString)"
        )
    }

    /// Updates the idle poll interval for the active agent with the given role.
    func updatePollInterval(for role: AgentRole, interval: TimeInterval) async {
        agentPollIntervals[role] = interval
        guard let runtime else { return }
        await runtime.updatePollInterval(for: role, interval: interval)
    }

    /// Updates the maximum tool calls per LLM response for the active agent with the given role.
    func updateMaxToolCalls(for role: AgentRole, count: Int) async {
        agentMaxToolCalls[role] = count
        guard let runtime else { return }
        await runtime.updateMaxToolCalls(for: role, count: count)
    }

    /// Stops the first running task, if any. Intended for ESC-key quick-stop.
    func stopCurrentTask() async {
        guard let runningTask = tasks.first(where: { $0.status == .running }) else { return }
        await stopTask(id: runningTask.id)
    }

    /// Master kill switch — stops everything immediately.
    func stopAll() async {
        guard let runtime else { return }
        await runtime.stopAll()
        speechController.stopAll()
        isRunning = false
        processingRoles.removeAll()
        agentToolNames.removeAll()
        inspectorStore.clearAll()
        channelStreamTask?.cancel()
        channelStreamTask = nil
        self.runtime = nil

        // Mark any tasks that were mid-flight as interrupted.
        // Read from the store directly to get the most current state after agents have stopped.
        if let store = taskStore {
            let liveTasks = await store.allTasks()
            for task in liveTasks where task.status == .running {
                await store.updateStatus(id: task.id, status: .interrupted)
            }
        }

        // Persist final state
        persistMessages()
        persistTasks()
        await usageStore.flush()
    }

    /// Clears the abort state and allows restart.
    func resetAbort() {
        isAborted = false
        abortReason = ""
    }

    /// Clears the message display and inspector snapshots. The full history is always retained on disk.
    func clearLog() {
        messages.removeAll()
        inspectorStore.clearAll()
    }

    /// Prepends the persisted history before the current live messages.
    func restoreHistory() {
        let currentIDs = Set(messages.map(\.id))
        let restoredHistory = allPersistedMessages.filter { !currentIDs.contains($0.id) }
        messages = restoredHistory + messages
        hasRestoredHistory = true
    }

    // MARK: - Attachments

    /// Processes file URLs from a file picker, clipboard paste, or drag-and-drop.
    func addAttachments(from urls: [URL]) {
        for url in urls {
            // Security-scoped access is needed for fileImporter URLs (sandboxed).
            // Clipboard and drag-drop URLs are not security-scoped, so this returns false —
            // we still proceed and attempt to read.
            let didAccessScope = url.startAccessingSecurityScopedResource()
            defer {
                if didAccessScope { url.stopAccessingSecurityScopedResource() }
            }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                print("[AgentSmith] Failed to read attachment \(url.lastPathComponent): \(error)")
                continue
            }

            let mimeType = Self.mimeType(for: url)
            let attachment = Attachment(
                filename: url.lastPathComponent,
                mimeType: mimeType,
                byteCount: data.count,
                data: data
            )
            pendingAttachments.append(attachment)
        }
    }

    /// Removes a pending attachment before sending.
    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Adds an attachment from raw data (e.g. clipboard paste).
    func addAttachment(data: Data, filename: String, mimeType: String) {
        let attachment = Attachment(
            filename: filename,
            mimeType: mimeType,
            byteCount: data.count,
            data: data
        )
        pendingAttachments.append(attachment)
    }

    /// Reads image or file data from the pasteboard and adds as pending attachments.
    /// Returns `true` if anything was pasted.
    func pasteFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general

        // 1. Try file URLs first (covers copied files from Finder)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            addAttachments(from: urls)
            return true
        }

        // 2. Try image data (covers screenshots, copied images)
        if let tiffData = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            addAttachment(
                data: pngData,
                filename: "Pasted Image \(Self.attachmentTimestamp()).png",
                mimeType: "image/png"
            )
            return true
        }

        return false
    }

    /// Generates a filesystem-safe timestamp string for auto-named attachments.
    /// Uses a fixed POSIX locale so output is deterministic regardless of user settings.
    static func attachmentTimestamp() -> String {
        attachmentTimestampFormatter.string(from: Date())
    }

    private static let attachmentTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    // MARK: - Persistence

    /// Resolves each agent role to its assigned ModelConfiguration, for inspector display.
    var resolvedAgentConfigs: [AgentRole: ModelConfiguration] {
        var result: [AgentRole: ModelConfiguration] = [:]
        for (role, configID) in agentAssignments {
            if let config = llmKit.configurations.first(where: { $0.id == configID }) {
                result[role] = config
            }
        }
        return result
    }

    /// Whether all agent roles have valid assigned configurations.
    var allAgentConfigsValid: Bool {
        AgentRole.requiredRoles.allSatisfy { role in
            guard let configID = agentAssignments[role],
                  let config = llmKit.configurations.first(where: { $0.id == configID }),
                  config.isValid else { return false }
            return true
        }
    }

    /// Deletes a model configuration and unassigns any agent roles that reference it.
    func deleteConfiguration(id: UUID) {
        for (role, configID) in agentAssignments where configID == id {
            agentAssignments[role] = nil
        }
        llmKit.deleteConfiguration(id: id)
    }

    /// Returns the `ModelConfiguration` dedicated to the given agent role, creating or
    /// cloning one as needed so that edits to it never affect another role's settings.
    ///
    /// Behavior:
    /// 1. If the role has no assignment, creates a new empty configuration, assigns it,
    ///    and returns it.
    /// 2. If the assigned configuration is also assigned to a different role, clones it
    ///    (with a fresh ID), reassigns the current role to the clone, and returns the clone.
    /// 3. Otherwise returns the existing assigned configuration unchanged.
    ///
    /// The agent-centric Model section in `AgentConfigSheet` calls this on appear so that
    /// any edits go to a config owned exclusively by this role. Always returns a config —
    /// the starter path falls through unconditionally if no assignment exists.
    @discardableResult
    func ensureDedicatedConfig(for role: AgentRole) -> ModelConfiguration {
        if let existingID = agentAssignments[role],
           let existing = llmKit.configurations.first(where: { $0.id == existingID }) {
            let sharedWith = agentAssignments.filter { $0.value == existingID && $0.key != role }
            if sharedWith.isEmpty {
                return existing
            }
            // Shared — clone and reassign so this role owns its own config. Copy-and-mutate
            // off the existing struct so any new fields added to ModelConfiguration are
            // automatically picked up here.
            var clone = existing
            clone.id = UUID()
            clone.name = "\(role.displayName) — \(existing.modelID)"
            llmKit.addConfiguration(clone)
            agentAssignments[role] = clone.id
            persistAgentAssignments()
            return clone
        }

        // No assignment yet — pick a sensible starter config (any existing one) or build
        // an empty placeholder so the user can fill it in.
        let starter: ModelConfiguration
        if let firstProvider = llmKit.providers.first {
            starter = ModelConfiguration(
                id: UUID(),
                name: "\(role.displayName) — \(firstProvider.name)",
                providerID: firstProvider.id,
                modelID: "",
                temperature: 0.7,
                maxOutputTokens: 4096,
                maxContextTokens: 128_000
            )
        } else {
            starter = ModelConfiguration(
                id: UUID(),
                name: "\(role.displayName)",
                providerID: "",
                modelID: ""
            )
        }
        llmKit.addConfiguration(starter)
        agentAssignments[role] = starter.id
        persistAgentAssignments()
        return starter
    }

    /// Updates the agent's dedicated configuration in place.
    ///
    /// If an `undoManager` is supplied, registers an inverse action that restores the
    /// previous configuration. The inverse handler also re-calls this method, which
    /// re-registers the *forward* inverse — giving us free redo support via the
    /// standard UndoManager ping-pong pattern.
    func updateAgentConfig(_ config: ModelConfiguration, undoManager: UndoManager? = nil) {
        let previous = llmKit.configurations.first { $0.id == config.id }
        llmKit.updateConfiguration(config)
        guard let previous, let undoManager, previous != config else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.updateAgentConfig(previous, undoManager: undoManager)
        }
        undoManager.setActionName("Change \(config.name)")
    }

    /// Saves the nickname to UserDefaults and syncs it to the static used by system prompts.
    func persistNickname() {
        UserDefaults.standard.set(nickname, forKey: "userNickname")
        AgentRole.userNickname = nickname
    }

    /// Saves agent assignments to UserDefaults.
    func persistAgentAssignments() {
        do {
            let data = try JSONEncoder().encode(agentAssignments)
            UserDefaults.standard.set(data, forKey: "agentAssignments")
        } catch {
            print("[AgentSmith] Failed to encode agent assignments: \(error)")
        }
    }

    // MARK: - Private

    private func persistMessages() {
        let snapshot = allPersistedMessages
        Task.detached { [persistenceManager, logger] in
            do {
                try await persistenceManager.saveChannelLog(snapshot)
            } catch {
                logger.error("Failed to persist messages: \(error)")
            }
        }
    }

    // MARK: - Memory Editor Support

    /// Refreshes the published memory arrays from the memory store.
    func refreshMemories() async {
        guard let memoryStore = await runtime?.memoryStore else { return }
        storedMemories = await memoryStore.allMemories()
        storedTaskSummaries = await memoryStore.allTaskSummaries()
    }

    /// Deletes a memory by ID.
    func deleteMemory(id: UUID) async {
        guard let memoryStore = await runtime?.memoryStore else { return }
        await memoryStore.delete(id: id)
    }

    /// Errors thrown by the memory editor's search helpers, surfaced to the UI.
    enum MemorySearchUIError: LocalizedError {
        case smithNotRunning
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .smithNotRunning:
                return "Memory store is unavailable. Start Smith from the toolbar to load and search memories."
            case .underlying(let error):
                return "Search failed: \(error.localizedDescription)"
            }
        }
    }

    /// Searches memories by semantic similarity. Throws so the editor can distinguish
    /// "no results" from "search failed" and surface a meaningful message to the user.
    func searchMemories(query: String, limit: Int = 20) async throws -> [MemorySearchResult] {
        guard let memoryStore = await runtime?.memoryStore else {
            throw MemorySearchUIError.smithNotRunning
        }
        do {
            return try await memoryStore.searchMemories(query: query, limit: limit, threshold: 0.0)
        } catch {
            print("[AppViewModel] Memory search failed: \(error)")
            throw MemorySearchUIError.underlying(error)
        }
    }

    /// Searches task summaries by semantic similarity. Same error contract as `searchMemories`.
    func searchTaskSummaries(query: String, limit: Int = 20) async throws -> [TaskSummarySearchResult] {
        guard let memoryStore = await runtime?.memoryStore else {
            throw MemorySearchUIError.smithNotRunning
        }
        do {
            return try await memoryStore.searchTaskSummaries(query: query, limit: limit, threshold: 0.0)
        } catch {
            print("[AppViewModel] Task summary search failed: \(error)")
            throw MemorySearchUIError.underlying(error)
        }
    }

    /// Updates a memory's content and/or tags via the Memory editor. Marked as a `.user`
    /// edit so the entry's `lastUpdatedBy` reflects who made the change.
    func updateMemory(id: UUID, content: String? = nil, tags: [String]? = nil) async throws {
        guard let memoryStore = await runtime?.memoryStore else { return }
        try await memoryStore.update(id: id, content: content, tags: tags, updatedBy: .user)
    }

    private func persistMemories(memoryStore: MemoryStore) {
        Task.detached { [persistenceManager, logger] in
            do {
                let memories = await memoryStore.allMemories()
                let taskSummaries = await memoryStore.allTaskSummaries()
                try await persistenceManager.saveMemories(memories)
                try await persistenceManager.saveTaskSummaries(taskSummaries)
            } catch {
                logger.error("Failed to persist memories: \(error)")
            }
        }
    }

    private func persistTasks() {
        let tasksToSave = tasks
        Task.detached { [persistenceManager, logger] in
            do {
                try await persistenceManager.saveTasks(tasksToSave)
            } catch {
                logger.error("Failed to persist tasks: \(error)")
            }
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
