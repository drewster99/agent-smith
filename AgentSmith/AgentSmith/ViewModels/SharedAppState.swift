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
    /// Set to true after `loadPersistedState()` finishes.
    var hasLoadedPersistedState = false
    /// Tracks the in-flight `loadPersistedState()` call so concurrent windows that all
    /// trigger bootstrap on first appear share a single run rather than double-executing
    /// the migrations and model refresh.
    private var loadTask: Task<Void, Never>?

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

        // Run one-shot UsageRecord migrations (shared across all sessions).
        await migrateUsageRecords()

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
    func ensureSemanticEngine() async throws -> SemanticSearchEngine {
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
    func ensureMemoryStore() async throws -> MemoryStore {
        if let store = memoryStore { return store }
        let engine = try await ensureSemanticEngine()
        let store = MemoryStore(engine: engine)

        // Wire persistence + UI refresh BEFORE restore so migration re-embed firings are captured.
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

                // Re-embed entries whose stored model ID doesn't match the current engine.
                let reembedStart = Date()
                let memCount = try await store.reembedStaleMemories()
                // Task summaries' fuller embeddings require the originating AgentTask (for
                // description, timestamps) but those now live per-session and aren't loaded
                // yet at app-bootstrap time. Passing an empty task list forces the orphan
                // path in `reembedStaleTaskSummaries`: re-embed from `title + summary`
                // stored on the entry itself. Slight quality regression on model-change
                // re-embed only; fresh summaries saved after task completion continue to
                // include the full description text via `MemoryStore.saveTaskSummary`.
                let taskCount = try await store.reembedStaleTaskSummaries(tasks: [])
                let reembedMs = Int(Date().timeIntervalSince(reembedStart) * 1000)
                if memCount > 0 || taskCount > 0 {
                    print("[AgentSmith] Re-embedded \(memCount) stale memories, \(taskCount) stale task summaries in \(reembedMs)ms")
                }
            }
        } catch {
            print("[AgentSmith] Failed to load/re-embed memories: \(error)")
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

    // MARK: - Usage Record Migrations

    /// One-shot migration pass over UsageRecords. Runs four idempotent backfills and saves
    /// once at the end if anything changed. See AppViewModel's previous implementation for
    /// the detailed design.
    private func migrateUsageRecords() async {
        // TODO: Remove all four migrations after 05/10/2026
        do {
            var rawRecords = try await basePersistence.loadUsageRecords()
            var totalModified = 0

            // --- Pass 1: Configuration backfill ---
            var configBackfilled = 0
            for i in rawRecords.indices {
                let record = rawRecords[i]
                if record.providerID != nil && record.configuration != nil { continue }
                guard let configID = record.configurationID,
                      let config = llmKit.configurations.first(where: { $0.id == configID }),
                      let provider = llmKit.providers.first(where: { $0.id == config.providerID }),
                      provider.apiType.rawValue == record.providerType else { continue }
                rawRecords[i] = record.replacing(
                    providerID: config.providerID,
                    configuration: config,
                    configurationID: configID
                )
                configBackfilled += 1
            }
            totalModified += configBackfilled
            if configBackfilled > 0 {
                print("[AgentSmith] Migration pass 1 (configuration): backfilled \(configBackfilled) records.")
            }

            // Smith taskID backfill used to require the per-session task list and is
            // therefore skipped here — all records still carrying nil taskIDs have been
            // present for many months now and remain nil-joined; the cost of threading
            // every session's tasks into the shared bootstrap isn't worth it.

            // Passes 3 and 4 scan $TMPDIR/AgentSmith-LLM-Logs/ response files.
            let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSmith-LLM-Logs")
            let fm = FileManager.default
            let logDirExists = fm.fileExists(atPath: logDir.path)

            // --- Pass 3: Tool call backfill from API response logs ---
            var toolCallBackfilled = 0
            if rawRecords.contains(where: { $0.toolCallNames == nil }) {
                if logDirExists {
                    struct LogEntry { let mtime: TimeInterval; let toolNames: [String] }
                    var logEntries: [LogEntry] = []
                    // try? justified: log files live in $TMPDIR and may be partially
                    // written, cleaned up by the OS, or have stale metadata. Skipping
                    // unreadable files is the correct degradation for a best-effort backfill.
                    let logFiles = (try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                    for file in logFiles where file.lastPathComponent.hasSuffix("_response.json") {
                        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                              let mdate = attrs[.modificationDate] as? Date,
                              let data = try? Data(contentsOf: file),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        var names: [String] = []
                        if let choices = json["choices"] as? [[String: Any]] {
                            for choice in choices {
                                for tc in ((choice["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]]) ?? [] {
                                    if let name = (tc["function"] as? [String: Any])?["name"] as? String { names.append(name) }
                                }
                            }
                        } else if let content = json["content"] as? [[String: Any]] {
                            for block in content where block["type"] as? String == "tool_use" {
                                if let name = block["name"] as? String { names.append(name) }
                            }
                        } else if let candidates = json["candidates"] as? [[String: Any]] {
                            for cand in candidates {
                                for part in ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
                                    if let fc = part["functionCall"] as? [String: Any], let name = fc["name"] as? String { names.append(name) }
                                }
                            }
                        }
                        logEntries.append(LogEntry(mtime: mdate.timeIntervalSinceReferenceDate, toolNames: names))
                    }
                    logEntries.sort { $0.mtime < $1.mtime }
                    let logMtimes = logEntries.map(\.mtime)

                    let matchWindow: TimeInterval = 10
                    for i in rawRecords.indices where rawRecords[i].toolCallNames == nil {
                        let ts = rawRecords[i].timestamp.timeIntervalSinceReferenceDate
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
                            let d = abs(logEntries[idx].mtime - ts)
                            if logEntries[idx].mtime > ts + matchWindow { break }
                            if d < bestDist { bestDist = d; bestIdx = idx }
                            idx += 1
                        }
                        guard bestIdx >= 0 else { continue }
                        let matched = logEntries[bestIdx]
                        rawRecords[i] = rawRecords[i].replacing(
                            toolCallCount: matched.toolNames.count,
                            toolCallNames: matched.toolNames
                        )
                        toolCallBackfilled += 1
                    }
                    totalModified += toolCallBackfilled
                }
            }

            // --- Pass 4: Cache token backfill ---
            var cacheBackfilled = 0
            let cacheHWMKey = "cacheTokenBackfillHighWaterMark"
            let previousHWM = UserDefaults.standard.object(forKey: cacheHWMKey) as? Date ?? .distantPast
            let openAICompatibleTypes: Set<String> = [
                "openAICompatible", "lmStudio", "mistral", "huggingFace",
                "xAI", "zAI", "metaLlama", "alibabaCloud", "openRouter"
            ]
            let candidateIndices = rawRecords.indices.filter { i in
                let r = rawRecords[i]
                return (r.providerType == "gemini" || openAICompatibleTypes.contains(r.providerType))
                    && r.cacheReadTokens == 0
                    && r.timestamp > previousHWM
            }

            if !candidateIndices.isEmpty {
                var rawUsageBackfilled = 0
                var unresolvedIndices: [Int] = []
                for i in candidateIndices {
                    let r = rawRecords[i]
                    // try? justified: rawUsage is best-effort archival data. If a
                    // record's stored JSON is corrupt, empty, or otherwise unparseable,
                    // fall through to the log-file fallback (Strategy 2). Throwing
                    // here would abort the entire migration over one bad record.
                    guard let rawUsage = r.rawUsage,
                          let data = rawUsage.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        unresolvedIndices.append(i)
                        continue
                    }
                    let cacheRead = Self.extractCacheRead(from: obj, providerType: r.providerType)
                    if cacheRead > 0 {
                        rawRecords[i] = r.replacing(cacheReadTokens: cacheRead)
                        rawUsageBackfilled += 1
                    }
                }
                cacheBackfilled += rawUsageBackfilled

                if !unresolvedIndices.isEmpty, logDirExists {
                    struct CacheLogEntry { let mtime: TimeInterval; let cacheReadTokens: Int }
                    var logEntries: [CacheLogEntry] = []
                    // try? justified: temp directory files may be missing, partially
                    // written, or have stale metadata.
                    let logFiles = (try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                    for file in logFiles where file.lastPathComponent.hasSuffix("_response.json") {
                        let name = file.lastPathComponent
                        // Log filenames contain the provider adapter class name (e.g. "_Gemini_",
                        // "_OpenAI_"). This is a convention set by the LLM logging layer — if
                        // adapter naming changes, this filter must be updated accordingly.
                        guard name.contains("_Gemini_") || name.contains("_OpenAI_") else { continue }
                        guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                              let mdate = attrs[.modificationDate] as? Date,
                              let data = try? Data(contentsOf: file),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        var cacheRead = 0
                        if name.contains("_Gemini_") {
                            if let meta = json["usageMetadata"] as? [String: Any] {
                                cacheRead = meta["cachedContentTokenCount"] as? Int ?? 0
                            }
                        } else {
                            if let usage = json["usage"] as? [String: Any],
                               let details = usage["prompt_tokens_details"] as? [String: Any] {
                                cacheRead = details["cached_tokens"] as? Int ?? 0
                            }
                        }
                        logEntries.append(CacheLogEntry(mtime: mdate.timeIntervalSinceReferenceDate, cacheReadTokens: cacheRead))
                    }
                    logEntries.sort { $0.mtime < $1.mtime }
                    let logMtimes = logEntries.map(\.mtime)

                    var logBackfilled = 0
                    let matchWindow: TimeInterval = 10
                    for i in unresolvedIndices {
                        let ts = rawRecords[i].timestamp.timeIntervalSinceReferenceDate
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
                            let d = abs(logEntries[idx].mtime - ts)
                            if logEntries[idx].mtime > ts + matchWindow { break }
                            if d < bestDist { bestDist = d; bestIdx = idx }
                            idx += 1
                        }
                        guard bestIdx >= 0, logEntries[bestIdx].cacheReadTokens > 0 else { continue }
                        rawRecords[i] = rawRecords[i].replacing(
                            cacheReadTokens: logEntries[bestIdx].cacheReadTokens
                        )
                        logBackfilled += 1
                    }
                    cacheBackfilled += logBackfilled
                }
            }
            totalModified += cacheBackfilled

            var saveSucceeded = true
            if totalModified > 0 {
                do {
                    try await basePersistence.saveUsageRecords(rawRecords)
                    print("[AgentSmith] UsageRecord migrations: saved \(totalModified) total modified records (config=\(configBackfilled), toolCalls=\(toolCallBackfilled), cache=\(cacheBackfilled)).")
                } catch {
                    logger.error("Failed to save migrated usage records: \(error.localizedDescription)")
                    saveSucceeded = false
                }
            }

            if saveSucceeded, let latestTimestamp = rawRecords.map(\.timestamp).max() {
                UserDefaults.standard.set(latestTimestamp, forKey: cacheHWMKey)
            }
        } catch {
            logger.error("Failed to load usage records for migration: \(error.localizedDescription)")
        }
    }

    static func extractCacheRead(from usageObject: [String: Any], providerType: String) -> Int {
        if providerType == "gemini" {
            return usageObject["cachedContentTokenCount"] as? Int ?? 0
        }
        if let details = usageObject["prompt_tokens_details"] as? [String: Any] {
            return details["cached_tokens"] as? Int ?? 0
        }
        return 0
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
