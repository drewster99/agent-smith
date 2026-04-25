import SwiftUI
import AgentSmithKit
import SwiftLLMKit
import SemanticSearch
import os

/// App-global state shared by every session / tab.
///
/// Holds the LLM configuration catalog, speech, billing, the embedding engine, and the
/// shared memory corpus. Created once at app launch and passed to every `AppViewModel`.
///
/// Memories and task summaries are shared across all sessions — they represent facts
/// Smith has learned about the user and the world. Per-session `OrchestrationRuntime`
/// instances receive `sharedMemoryStore` so each Smith reads and writes the same pool.
@Observable
@MainActor
final class SharedAppState {
    /// The user's preferred nickname, shown in the UI and injected into system prompts.
    var nickname: String = ""
    /// Whether to auto-start sessions when all their agent configs are valid on launch.
    var autoStartEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "autoStartEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "autoStartEnabled")
    }() {
        didSet { UserDefaults.standard.set(autoStartEnabled, forKey: "autoStartEnabled") }
    }

    /// SwiftLLMKit instance managing providers, models, and configurations (shared catalog).
    let llmKit = LLMKitManager(
        appIdentifier: Bundle.main.bundleIdentifier ?? "com.agentsmith",
        keychainServicePrefix: "com.agentsmith.SwiftLLMKit"
    )

    let speechController = SpeechController()

    /// Persistent token usage analytics store (app-global billing rollup).
    private(set) var usageStore: UsageStore

    /// Semantic search engine, lazily created on first `start()` by any session and reused
    /// thereafter so the MLX model isn't reloaded on every Run/Stop cycle or per-session.
    private(set) var semanticSearchEngine: SemanticSearchEngine?

    /// Most recent progress event from `SemanticSearchEngine.prepare()`.
    var embeddingPrepareProgress: PrepareProgress?

    /// Shared memory store — all session runtimes write to and read from the same corpus.
    /// Created lazily in `ensureMemoryStore()` once the semantic engine is prepared.
    private(set) var memoryStore: MemoryStore?

    /// All stored memories, refreshed when the memory store changes (backs MemoryEditorView).
    var storedMemories: [MemoryEntry] = []
    /// All stored task summaries, refreshed when the memory store changes.
    var storedTaskSummaries: [TaskSummaryEntry] = []

    /// Set when a load/decode operation fails during startup; drives the error alert.
    var startupError: String?
    /// ID of the session whose window is currently key (frontmost). Updated by
    /// `SessionScene` via `NSWindow.didBecomeKeyNotification`. Used by commands like
    /// Cmd+N and Close Session so they target the focused tab, not an arbitrary one.
    var focusedSessionID: UUID?
    /// Signal from the File menu → the focused `SessionScene` that it should show a
    /// close-confirmation sheet for this session ID. Cleared by the scene after handling.
    /// Only the scene whose session matches acts on it, so the menu command correctly
    /// routes to the frontmost tab.
    var closeSessionRequestID: UUID?
    /// Same pattern for rename.
    var renameSessionRequestID: UUID?
    /// Set to true after `loadPersistedState()` finishes.
    var hasLoadedPersistedState = false
    /// Tracks the in-flight `loadPersistedState()` call so concurrent windows that all
    /// trigger bootstrap on first appear share a single run rather than double-executing
    /// the migrations and model refresh.
    private var loadTask: Task<Void, Never>?
    /// Tracks the in-flight `ensureSemanticEngine()` call so concurrent session starts
    /// share a single MLX model load. Without this, two tabs auto-starting on launch
    /// would each allocate a fresh `SemanticSearchEngine` and prepare independently.
    private var semanticEngineTask: Task<SemanticSearchEngine, Error>?
    /// Tracks the in-flight `ensureMemoryStore()` call so concurrent session starts
    /// share a single `MemoryStore` instance — critical for the "shared corpus"
    /// invariant. Without this, each tab would get a different store, writes would
    /// diverge, and `memories.json` persistence would be last-writer-wins.
    private var memoryStoreTask: Task<MemoryStore, Error>?

    /// Default agent assignments (from bundled defaults) — used when creating a new session.
    private(set) var defaultAgentAssignments: [AgentRole: UUID] = [:]
    /// Default agent tunings (from bundled defaults) — used when creating a new session.
    private(set) var defaultAgentPollIntervals: [AgentRole: TimeInterval] = [
        .smith: 20, .brown: 25, .jones: 13
    ]
    private(set) var defaultAgentMaxToolCalls: [AgentRole: Int] = [
        .smith: 100, .brown: 100, .jones: 100
    ]
    private(set) var defaultAgentMessageDebounceIntervals: [AgentRole: TimeInterval] = [
        .smith: 1, .brown: 1, .jones: 1
    ]

    /// Base-path persistence manager for shared files (memories, usage, overrides, sessions list).
    let basePersistence: PersistenceManager

    private let logger = Logger(subsystem: "com.agentsmith", category: "SharedAppState")

    init() {
        let pm = PersistenceManager()
        self.basePersistence = pm
        self.usageStore = UsageStore(persistence: pm)
    }

    // MARK: - Bootstrap

    /// Loads shared persisted state: nickname, LLM providers/configs/models, bundled defaults,
    /// memories, task summaries, usage records, and model overrides.
    /// Per-session state is loaded by each session's `AppViewModel` separately.
    /// Safe to call from multiple windows concurrently — the first call does the work,
    /// subsequent callers await the same Task.
    func loadPersistedState() async {
        if hasLoadedPersistedState { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadPersistedState()
        }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    private func performLoadPersistedState() async {
        // Load nickname early so display names and prompts pick it up.
        nickname = UserDefaults.standard.string(forKey: "userNickname") ?? ""
        AgentRole.userNickname = nickname

        // Configure verbose logging for SwiftLLMKit services and providers.
        LLMRequestLogger.logDirectoryName = "AgentSmith-LLM-Logs"
        llmKit.verboseLogging = true
        ModelFetchService.verboseLogging = true
        ModelMetadataService.verboseLogging = true

        // Load SwiftLLMKit state (providers, configs, cached models).
        llmKit.load()

        // Load bundled defaults — these provide baseline values for tunings, speech,
        // and (on first install) providers, configurations, and agent assignments.
        do {
            let bundled = try DefaultsLoader.loadBundledDefaults()
            for (role, tuning) in bundled.agentTuning {
                defaultAgentPollIntervals[role] = tuning.pollInterval
                defaultAgentMaxToolCalls[role] = tuning.maxToolCalls
                defaultAgentMessageDebounceIntervals[role] = tuning.messageDebounceInterval
            }
            speechController.applyBundledDefaults(bundled.speech)

            let didBootstrapKey = "didBootstrapBundledDefaults"
            if !UserDefaults.standard.bool(forKey: didBootstrapKey) {
                for provider in bundled.providers {
                    let apiKey = bundled.providerAPIKeys[provider.id] ?? ""
                    try llmKit.addProvider(provider, apiKey: apiKey)
                }
                for config in bundled.modelConfigurations {
                    llmKit.addConfiguration(config)
                }
                defaultAgentAssignments = bundled.agentAssignments
                UserDefaults.standard.set(true, forKey: didBootstrapKey)
            } else {
                defaultAgentAssignments = bundled.agentAssignments
            }
        } catch {
            let msg = "No bundled defaults (using hardcoded): \(error)"
            print("[AgentSmith] \(msg)")
            startupError = msg
        }

        // Load user model metadata overrides and inject into LLMKitManager.
        do {
            let overrides = try await basePersistence.loadUserModelOverrides()
            if !overrides.isEmpty {
                llmKit.setUserOverrides(overrides)
            }
        } catch {
            logger.error("Failed to load user model overrides: \(error.localizedDescription)")
        }

        // Load persisted usage records into the shared store.
        await usageStore.load()

        // Diagnostic: warn if a cache-supporting provider has 0% hit rate.
        await runUsageHealthCheck()

        // Refresh model catalog (YYYYMMDD-gated).
        await llmKit.refreshIfNeeded()
        llmKit.validateConfigurations()

        hasLoadedPersistedState = true
    }

    /// Creates the shared semantic search engine on demand, preparing the MLX model.
    /// Subsequent calls return the existing engine without re-preparation.
    /// Concurrent callers (multiple windows auto-starting at launch) share a single
    /// in-flight `prepare()` run via `semanticEngineTask`.
    func ensureSemanticEngine() async throws -> SemanticSearchEngine {
        if let engine = semanticSearchEngine { return engine }
        if let existing = semanticEngineTask {
            return try await existing.value
        }
        let task = Task { @MainActor [weak self] () -> SemanticSearchEngine in
            guard let self else { throw CancellationError() }
            return try await self.performEnsureSemanticEngine()
        }
        semanticEngineTask = task
        defer { semanticEngineTask = nil }
        return try await task.value
    }

    private func performEnsureSemanticEngine() async throws -> SemanticSearchEngine {
        if let engine = semanticSearchEngine { return engine }
        let engine = SemanticSearchEngine()
        for try await progress in engine.prepare() {
            embeddingPrepareProgress = progress
            let pct = Int(progress.fractionCompleted * 100)
            print("[AgentSmith] Embedding model: \(progress.phase) \(pct)%")
        }
        embeddingPrepareProgress = nil
        semanticSearchEngine = engine
        return engine
    }

    /// Creates the shared memory store on demand (after the semantic engine is ready) and
    /// restores memories + task summaries from disk. Wires persistence + UI refresh once.
    /// Concurrent callers share a single in-flight creation via `memoryStoreTask`, so
    /// every session's runtime ends up with the same `MemoryStore` instance.
    func ensureMemoryStore() async throws -> MemoryStore {
        if let store = memoryStore { return store }
        if let existing = memoryStoreTask {
            return try await existing.value
        }
        let task = Task { @MainActor [weak self] () -> MemoryStore in
            guard let self else { throw CancellationError() }
            return try await self.performEnsureMemoryStore()
        }
        memoryStoreTask = task
        defer { memoryStoreTask = nil }
        return try await task.value
    }

    private func performEnsureMemoryStore() async throws -> MemoryStore {
        if let store = memoryStore { return store }
        let engine = try await ensureSemanticEngine()
        let store = MemoryStore(engine: engine)

        await store.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.persistMemories(memoryStore: store)
                await self.refreshMemories(from: store)
            }
        }

        do {
            let savedMemories = try await basePersistence.loadMemories()
            let savedTaskSummaries = try await basePersistence.loadTaskSummaries()
            if !savedMemories.isEmpty || !savedTaskSummaries.isEmpty {
                await store.restore(memories: savedMemories, taskSummaries: savedTaskSummaries)
            }
        } catch {
            print("[AgentSmith] Failed to load memories: \(error)")
        }

        memoryStore = store
        await refreshMemories(from: store)
        return store
    }

    // MARK: - Nickname

    func persistNickname() {
        UserDefaults.standard.set(nickname, forKey: "userNickname")
        AgentRole.userNickname = nickname
    }

    // MARK: - Model Configuration (shared catalog)

    /// Deletes a model configuration from the shared catalog. Callers should iterate the
    /// session list (via `SessionManager`) and clear per-session assignments that point at
    /// the deleted ID — `SessionManager.deleteConfiguration(id:)` does both.
    func deleteConfiguration(id: UUID) {
        llmKit.deleteConfiguration(id: id)
    }

    /// Updates a model configuration in place. Supports undo through the supplied UndoManager.
    func updateAgentConfig(_ config: ModelConfiguration, undoManager: UndoManager? = nil) {
        let previous = llmKit.configurations.first { $0.id == config.id }
        llmKit.updateConfiguration(config)
        guard let previous, let undoManager, previous != config else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.updateAgentConfig(previous, undoManager: undoManager)
        }
        undoManager.setActionName("Change \(config.name)")
    }

    // MARK: - Memory

    /// Refreshes `storedMemories` and `storedTaskSummaries` from the shared memory store.
    func refreshMemories() async {
        guard let store = memoryStore else { return }
        await refreshMemories(from: store)
    }

    private func refreshMemories(from store: MemoryStore) async {
        storedMemories = await store.allMemories()
        storedTaskSummaries = await store.allTaskSummaries()
    }

    private func persistMemories(memoryStore: MemoryStore) {
        Task.detached { [basePersistence, logger] in
            do {
                let memories = await memoryStore.allMemories()
                let taskSummaries = await memoryStore.allTaskSummaries()
                try await basePersistence.saveMemories(memories)
                try await basePersistence.saveTaskSummaries(taskSummaries)
            } catch {
                logger.error("Failed to persist memories: \(error)")
            }
        }
    }

    /// Deletes a memory by ID.
    func deleteMemory(id: UUID) async {
        guard let store = memoryStore else { return }
        await store.delete(id: id)
    }

    /// Errors thrown by the memory editor's search helpers, surfaced to the UI.
    enum MemorySearchUIError: LocalizedError {
        case storeUnavailable
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .storeUnavailable:
                return "Memory store is unavailable. Start a session from the toolbar to load and search memories."
            case .underlying(let error):
                return "Search failed: \(error.localizedDescription)"
            }
        }
    }

    func searchMemories(query: String, limit: Int = 20) async throws -> [MemorySearchResult] {
        guard let store = memoryStore else { throw MemorySearchUIError.storeUnavailable }
        do {
            return try await store.searchMemories(query: query, limit: limit, threshold: 0.0)
        } catch {
            print("[SharedAppState] Memory search failed: \(error)")
            throw MemorySearchUIError.underlying(error)
        }
    }

    func searchTaskSummaries(query: String, limit: Int = 20) async throws -> [TaskSummarySearchResult] {
        guard let store = memoryStore else { throw MemorySearchUIError.storeUnavailable }
        do {
            return try await store.searchTaskSummaries(query: query, limit: limit, threshold: 0.0)
        } catch {
            print("[SharedAppState] Task summary search failed: \(error)")
            throw MemorySearchUIError.underlying(error)
        }
    }

    /// Updates a memory's content and/or tags. Marked as a `.user` edit so the entry's
    /// `lastUpdatedBy` reflects who made the change.
    func updateMemory(id: UUID, content: String? = nil, tags: [String]? = nil) async throws {
        guard let store = memoryStore else { return }
        try await store.update(id: id, content: content, tags: tags, updatedBy: .user)
    }

    private func runUsageHealthCheck() async {
        let allRecords = await usageStore.allRecords()
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = allRecords.filter { $0.timestamp >= cutoff }
        guard recent.count >= 20 else { return }

        let cacheCapableProviders: Set<String> = [
            "anthropic", "gemini",
            "openAICompatible", "lmStudio", "mistral", "huggingFace",
            "xAI", "zAI", "metaLlama", "alibabaCloud", "openRouter"
        ]

        var byProvider: [String: (calls: Int, totalInput: Int, totalCacheRead: Int, withRawUsage: Int)] = [:]
        for record in recent where cacheCapableProviders.contains(record.providerType) {
            guard record.inputTokens >= 5000 else { continue }
            var entry = byProvider[record.providerType] ?? (0, 0, 0, 0)
            entry.calls += 1
            entry.totalInput += record.inputTokens
            entry.totalCacheRead += record.cacheReadTokens
            if record.rawUsage != nil { entry.withRawUsage += 1 }
            byProvider[record.providerType] = entry
        }

        for (provider, stats) in byProvider where stats.calls >= 20 {
            let hitRate = Double(stats.totalCacheRead) / Double(stats.totalInput)
            let rawUsageCoverage = Double(stats.withRawUsage) / Double(stats.calls)
            if hitRate == 0 {
                logger.warning("Usage health: provider \(provider) shows 0% cache hit rate across \(stats.calls) recent large calls (\(stats.totalInput) input tokens). Possible parser regression — verify the provider layer still extracts cache token fields. rawUsage coverage: \(Int(rawUsageCoverage * 100))%")
            } else {
                logger.info("Usage health: provider \(provider) cache hit rate \(String(format: "%.1f%%", hitRate * 100)) across \(stats.calls) recent calls. rawUsage coverage: \(Int(rawUsageCoverage * 100))%")
            }
        }
    }
}
