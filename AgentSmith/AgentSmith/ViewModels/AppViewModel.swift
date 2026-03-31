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
    /// Snapshots of each active agent's full LLM conversation history.
    var agentContexts: [AgentRole: [LLMMessage]] = [:]
    /// Snapshots of per-turn LLM call records for each active agent.
    var agentTurns: [AgentRole: [LLMTurnRecord]] = [:]
    /// Security evaluation records from Jones (SecurityEvaluator).
    var jonesEvaluationRecords: [EvaluationRecord] = []
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
    private var contextRefreshTask: Task<Void, Never>?
    private var persistenceManager = PersistenceManager()
    /// Full message history — a superset of `messages`. Never cleared; always written to disk.
    private var allPersistedMessages: [ChannelMessage] = []

    // MARK: - Lifecycle

    /// Loads persisted messages, tasks, and LLM configs from disk. Call on app launch.
    func loadPersistedState() async {
        // Load nickname early so display names and prompts pick it up.
        nickname = UserDefaults.standard.string(forKey: "userNickname") ?? ""
        AgentRole.userNickname = nickname

        // Configure verbose logging for SwiftLLMKit fetch services
        ModelFetchService.verboseLogging = LLMRequestLogger.logModelFetch
        ModelMetadataService.verboseLogging = LLMRequestLogger.logLiteLLM

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

            // Apply bundled provider/config/assignment defaults if no persisted state exists
            if llmKit.providers.isEmpty {
                for provider in bundled.providers {
                    let apiKey = bundled.providerAPIKeys[provider.id] ?? ""
                    try llmKit.addProvider(provider, apiKey: apiKey)
                }
                for config in bundled.modelConfigurations {
                    llmKit.addConfiguration(config)
                }
                agentAssignments = bundled.agentAssignments
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
            let savedMessages = try await persistenceManager.loadChannelLog()
            allPersistedMessages = savedMessages
            persistedHistoryCount = savedMessages.count
        } catch {
            let msg = "Failed to load channel log: \(error)"
            print("[AgentSmith] \(msg)")
            startupError = msg
        }

        do {
            var savedTasks = try await persistenceManager.loadTasks()
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
            if anyArchived { persistTasks() }

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

        // Refresh model catalog (YYYYMMDD-gated)
        await llmKit.refreshIfNeeded()
        llmKit.validateConfigurations()

        hasLoadedPersistedState = true
    }

    /// Resolves agent assignments into `LLMConfiguration` values the runtime understands.
    private func resolvedLLMConfigs() -> [AgentRole: LLMConfiguration] {
        var configs: [AgentRole: LLMConfiguration] = [:]
        for role in AgentRole.allCases {
            guard let configID = agentAssignments[role],
                  let modelConfig = llmKit.configurations.first(where: { $0.id == configID }),
                  let provider = llmKit.providers.first(where: { $0.id == modelConfig.providerID })
            else {
                continue
            }
            let apiKey = llmKit.apiKey(for: provider.id) ?? ""
            configs[role] = LLMConfiguration(
                endpoint: provider.endpoint,
                apiKey: apiKey,
                model: modelConfig.modelID,
                temperature: modelConfig.temperature,
                maxTokens: modelConfig.maxOutputTokens,
                contextWindowSize: modelConfig.maxContextTokens,
                providerType: provider.apiType,
                thinkingBudget: modelConfig.thinkingBudget,
                extendedCacheTTL: modelConfig.extendedCacheTTL
            )
        }
        return configs
    }

    /// Starts the system with current LLM configs.
    func start() async {
        guard !isRunning else { return }
        guard !isAborted else { return }

        let configs = resolvedLLMConfigs()

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

        let newRuntime = OrchestrationRuntime(llmConfigs: configs, agentTuning: tuning, embeddingService: embeddingService)
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
                self.agentContexts.removeAll()
                self.agentTurns.removeAll()
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
            }
        } catch {
            print("[AgentSmith] Failed to load memories: \(error)")
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

        await newRuntime.start()

        startContextRefresh()
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
        agentContexts.removeAll()
        agentTurns.removeAll()
        channelStreamTask?.cancel()
        channelStreamTask = nil
        contextRefreshTask?.cancel()
        contextRefreshTask = nil
        self.runtime = nil

        // Reset any tasks that were mid-flight back to pending.
        // Read from the store directly to get the most current state after agents have stopped.
        if let store = taskStore {
            let liveTasks = await store.allTasks()
            for task in liveTasks where task.status == .running {
                await store.updateStatus(id: task.id, status: .pending)
            }
        }

        // Persist final state
        persistMessages()
        persistTasks()
    }

    /// Clears the abort state and allows restart.
    func resetAbort() {
        isAborted = false
        abortReason = ""
    }

    /// Clears the message display and inspector snapshots. The full history is always retained on disk.
    func clearLog() {
        messages.removeAll()
        agentContexts.removeAll()
        agentTurns.removeAll()
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

    /// Polls each agent's conversation history every 2 seconds while the system is running.
    private func startContextRefresh() {
        contextRefreshTask?.cancel()
        contextRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let runtime = self.runtime else { break }
                for role in AgentRole.allCases {
                    if let context = await runtime.contextSnapshot(for: role) {
                        self.agentContexts[role] = context
                    } else if let archived = await runtime.archivedSnapshot(for: role) {
                        self.agentContexts[role] = archived.contextSnapshot
                    }
                    if let turns = await runtime.turnsSnapshot(for: role) {
                        self.agentTurns[role] = turns
                    } else if let archived = await runtime.archivedSnapshot(for: role) {
                        self.agentTurns[role] = archived.turnsSnapshot
                    }
                }
                // Fetch Jones security evaluation records.
                self.jonesEvaluationRecords = await runtime.evaluationHistory()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
        }
    }

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

    /// Searches memories by semantic similarity, returning results with scores.
    func searchMemories(query: String, limit: Int = 20) async -> [MemorySearchResult] {
        guard let memoryStore = await runtime?.memoryStore else { return [] }
        do {
            return try await memoryStore.searchMemories(query: query, limit: limit, threshold: 0.0)
        } catch {
            print("[AppViewModel] Memory search failed: \(error)")
            return []
        }
    }

    /// Searches task summaries by semantic similarity, returning results with scores.
    func searchTaskSummaries(query: String, limit: Int = 20) async -> [TaskSummarySearchResult] {
        guard let memoryStore = await runtime?.memoryStore else { return [] }
        do {
            return try await memoryStore.searchTaskSummaries(query: query, limit: limit, threshold: 0.0)
        } catch {
            print("[AppViewModel] Task summary search failed: \(error)")
            return []
        }
    }

    /// Updates a memory's content and/or tags. Re-embeds if content changed.
    func updateMemory(id: UUID, content: String? = nil, tags: [String]? = nil) async throws {
        guard let memoryStore = await runtime?.memoryStore else { return }
        try await memoryStore.update(id: id, content: content, tags: tags)
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
