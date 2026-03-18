import SwiftUI
import AgentSmithKit
import UniformTypeIdentifiers

/// Bridges the orchestration runtime to the SwiftUI UI.
@Observable
@MainActor
final class AppViewModel {
    var messages: [ChannelMessage] = []
    var tasks: [AgentTask] = []
    /// Set when a task action (archive, delete) is blocked; drives the error alert.
    var taskActionError: String? = nil
    var isRunning = false
    var isAborted = false
    var abortReason = ""
    var inputText = ""
    var pendingAttachments: [Attachment] = []
    /// Roles of agents that are currently waiting for an LLM response.
    var processingRoles: Set<AgentRole> = []
    /// Tools available to each agent role, populated when agents come online.
    var agentToolNames: [AgentRole: [String]] = [:]
    /// Whether the Inspector panel is visible.
    var showInspector = false
    /// Snapshots of each active agent's full LLM conversation history.
    var agentContexts: [AgentRole: [LLMMessage]] = [:]
    /// Current idle poll intervals for each agent role (seconds).
    var agentPollIntervals: [AgentRole: TimeInterval] = [
        .smith: 20, .brown: 25, .jones: 13
    ]

    /// Per-role LLM configurations, editable from settings.
    var smithConfig = LLMConfiguration.ollamaDefault
    var brownConfig = LLMConfiguration.ollamaDefault
    var jonesConfig = LLMConfiguration.ollamaDefault

    let speechController = SpeechController()

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
        do {
            let savedMessages = try await persistenceManager.loadChannelLog()
            messages = savedMessages
            allPersistedMessages = savedMessages
        } catch {
            print("[AgentSmith] Failed to load channel log: \(error)")
        }

        do {
            let savedTasks = try await persistenceManager.loadTasks()
            tasks = savedTasks
        } catch {
            print("[AgentSmith] Failed to load tasks: \(error)")
        }

        do {
            if let configs = try await persistenceManager.loadLLMConfigs() {
                if let smith = configs[.smith] { smithConfig = smith }
                if let brown = configs[.brown] { brownConfig = brown }
                if let jones = configs[.jones] { jonesConfig = jones }
            }
        } catch {
            print("[AgentSmith] Failed to load LLM configs: \(error)")
        }
    }

    /// Starts the system with current LLM configs.
    func start() async {
        guard !isRunning else { return }
        guard !isAborted else { return }

        let configs: [AgentRole: LLMConfiguration] = [
            .smith: smithConfig,
            .brown: brownConfig,
            .jones: jonesConfig
        ]

        let newRuntime = OrchestrationRuntime(llmConfigs: configs)
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

        await newRuntime.start()
        startContextRefresh()
    }

    /// Sends user input (with any pending attachments) to Smith.
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        guard let runtime else { return }

        let attachments = pendingAttachments
        inputText = ""
        pendingAttachments = []

        // Save attachment files to disk
        for attachment in attachments {
            Task.detached { [persistenceManager] in
                do {
                    try await persistenceManager.saveAttachment(attachment)
                } catch {
                    print("[AgentSmith] Failed to save attachment \(attachment.filename): \(error)")
                }
            }
        }

        await runtime.sendUserMessage(text, attachments: attachments)
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
        let succeeded = await taskStore?.archive(id: id) ?? true
        if !succeeded {
            taskActionError = "This task is in progress and cannot be archived."
        }
    }

    func deleteTask(id: UUID) async {
        let succeeded = await taskStore?.softDelete(id: id) ?? true
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
        let succeeded = await taskStore?.permanentlyDelete(id: id) ?? true
        if !succeeded {
            taskActionError = "This task is in progress and cannot be permanently deleted."
        }
    }

    func pauseTask(id: UUID) async {
        await taskStore?.pause(id: id)
    }

    func stopTask(id: UUID) async {
        await taskStore?.stop(id: id)
    }

    /// Resets a task to pending and asks Smith to retry it.
    func retryTask(_ task: AgentTask) async {
        await taskStore?.updateStatus(id: task.id, status: .pending)
        await taskStore?.unarchive(id: task.id)
        await sendDirectMessage(
            to: .smith,
            text: "Please retry this failed task:\nTitle: \(task.title)\nDescription: \(task.description)\nID: \(task.id.uuidString)"
        )
    }

    /// Resets a completed task to pending and asks Smith to run it again.
    func runTaskAgain(_ task: AgentTask) async {
        await taskStore?.updateStatus(id: task.id, status: .pending)
        await taskStore?.unarchive(id: task.id)
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

    /// Master kill switch — stops everything immediately.
    func stopAll() async {
        guard let runtime else { return }
        await runtime.stopAll()
        speechController.stopAll()
        isRunning = false
        processingRoles.removeAll()
        agentToolNames.removeAll()
        agentContexts.removeAll()
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
    }

    // MARK: - Attachments

    /// Processes file URLs from a file picker or drag-and-drop.
    func addAttachments(from urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

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
                    }
                }
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
        Task.detached { [persistenceManager] in
            do {
                try await persistenceManager.saveChannelLog(snapshot)
            } catch {
                print("[AgentSmith] Failed to persist messages: \(error)")
            }
        }
    }

    private func persistTasks() {
        let tasksToSave = tasks
        Task.detached { [persistenceManager] in
            do {
                try await persistenceManager.saveTasks(tasksToSave)
            } catch {
                print("[AgentSmith] Failed to persist tasks: \(error)")
            }
        }
    }

    /// Saves LLM configurations to disk so they survive app restart.
    func persistLLMConfigs() {
        let configs: [AgentRole: LLMConfiguration] = [
            .smith: smithConfig,
            .brown: brownConfig,
            .jones: jonesConfig
        ]
        Task.detached { [persistenceManager] in
            do {
                try await persistenceManager.saveLLMConfigs(configs)
            } catch {
                print("[AgentSmith] Failed to persist LLM configs: \(error)")
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
