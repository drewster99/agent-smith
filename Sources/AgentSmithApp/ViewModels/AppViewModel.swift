import SwiftUI
import AgentSmithKit
import UniformTypeIdentifiers

/// Bridges the orchestration runtime to the SwiftUI UI.
@Observable
@MainActor
final class AppViewModel {
    var messages: [ChannelMessage] = []
    var tasks: [AgentTask] = []
    var isRunning = false
    var isAborted = false
    var abortReason = ""
    var inputText = ""
    var pendingAttachments: [Attachment] = []

    /// Per-role LLM configurations, editable from settings.
    var smithConfig = LLMConfiguration.ollamaDefault
    var brownConfig = LLMConfiguration.ollamaDefault
    var jonesConfig = LLMConfiguration.ollamaDefault

    private var runtime: OrchestrationRuntime?
    private var channelStreamTask: Task<Void, Never>?
    private var persistenceManager = PersistenceManager()

    // MARK: - Lifecycle

    /// Loads persisted messages, tasks, and LLM configs from disk. Call on app launch.
    func loadPersistedState() async {
        do {
            let savedMessages = try await persistenceManager.loadChannelLog()
            messages = savedMessages
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
                self.runtime = nil
            }
        }

        // Subscribe to channel messages
        let channel = await newRuntime.channel
        channelStreamTask = Task { [weak self] in
            for await message in await channel.stream() {
                guard let self else { break }
                self.messages.append(message)
                self.persistMessages()
            }
        }

        // Subscribe to task changes
        let taskStore = await newRuntime.taskStore
        await taskStore.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allTasks = await taskStore.allTasks()
                self.tasks = allTasks
                self.persistTasks()
            }
        }

        await newRuntime.start()
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

    /// Master kill switch — stops everything immediately.
    func stopAll() async {
        guard let runtime else { return }
        await runtime.stopAll()
        isRunning = false
        channelStreamTask?.cancel()
        channelStreamTask = nil
        self.runtime = nil

        // Persist final state
        persistMessages()
        persistTasks()
    }

    /// Clears the abort state and allows restart.
    func resetAbort() {
        isAborted = false
        abortReason = ""
    }

    /// Clears the message log.
    func clearLog() {
        messages.removeAll()
        persistMessages()
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

    private func persistMessages() {
        let messagesToSave = messages
        Task.detached { [persistenceManager] in
            do {
                try await persistenceManager.saveChannelLog(messagesToSave)
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
