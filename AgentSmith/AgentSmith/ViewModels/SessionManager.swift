import SwiftUI
import AgentSmithKit
import os

/// Manages the lifecycle of all sessions (tabs/windows) and their view models.
///
/// Session windows are keyed by `Session.id` (UUID). The manager lazily instantiates
/// `AppViewModel` instances on first access and caches them so window focus toggles
/// don't rebuild the per-session runtime state.
@Observable
@MainActor
final class SessionManager {
    private(set) var sessions: [Session] = []
    /// Session IDs whose view models have been created (and therefore have loaded state).
    private(set) var viewModels: [UUID: AppViewModel] = [:]
    /// Set to true once `loadSessions()` completes so concurrent callers can short-circuit.
    private(set) var hasLoadedSessions = false
    /// Tracks the in-flight `loadSessions()` call so concurrent windows that all bootstrap
    /// on first appear share a single run rather than each creating a duplicate "Default".
    private var loadTask: Task<Void, Never>?

    let shared: SharedAppState
    private let logger = Logger(subsystem: "com.agentsmith", category: "SessionManager")

    init(shared: SharedAppState) {
        self.shared = shared
    }

    // MARK: - Loading / migration

    /// Loads the session list from disk. On first launch, migrates legacy single-session
    /// data into a "Default" session and/or creates an empty "Default" if nothing exists.
    /// Safe to call from multiple windows concurrently — the first call does the work,
    /// subsequent callers await the same Task.
    func loadSessions() async {
        if hasLoadedSessions { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadSessions()
        }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    private func performLoadSessions() async {
        do {
            sessions = try await shared.basePersistence.loadSessionList()
        } catch {
            logger.error("Failed to load session list: \(error.localizedDescription)")
            sessions = []
        }

        if sessions.isEmpty {
            await bootstrapDefaultSession()
        }
        hasLoadedSessions = true
    }

    /// Creates a "Default" session on first launch with empty per-session state;
    /// `loadPersistedState` will apply bundled defaults when the state is empty.
    private func bootstrapDefaultSession() async {
        let defaultSession = Session(name: "Default")
        let pm = PersistenceManager(sessionID: defaultSession.id)

        do {
            try await pm.saveSessionState(SessionState())
        } catch {
            logger.error("Failed to save Default session state: \(error.localizedDescription)")
        }

        sessions = [defaultSession]
        do {
            try await shared.basePersistence.saveSessionList(sessions)
        } catch {
            logger.error("Failed to save session list: \(error.localizedDescription)")
        }
    }

    // MARK: - View models

    /// Returns the view model for the given session ID, creating it on first access.
    /// Returns nil if the session ID isn't in the list.
    func viewModel(for id: UUID) -> AppViewModel? {
        if let cached = viewModels[id] { return cached }
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        let vm = AppViewModel(session: session, shared: shared)
        viewModels[id] = vm
        Task { await vm.loadPersistedState() }
        return vm
    }

    // MARK: - Mutations

    /// Creates a new empty session, persists the list, and returns the session.
    ///
    /// If `templateSessionID` resolves to a loaded view model, the new session inherits
    /// that session's per-session settings. Otherwise, any loaded view model is used as
    /// a fallback. This means Cmd+N from a specific tab gives the user another tab
    /// pre-configured like the one they were just using, rather than whichever VM
    /// happened to be first in the dictionary's hash order.
    @discardableResult
    func createSession(name: String = "New Session", templateSessionID: UUID? = nil) async -> Session {
        let session = Session(name: name)
        sessions.append(session)
        await persistSessions()

        // Inherit settings: prefer the caller's specified template, fall back to any loaded VM.
        let template: AppViewModel? = {
            if let templateSessionID, let explicit = viewModels[templateSessionID] {
                return explicit
            }
            return viewModels.values.first
        }()
        if let template {
            let inheritedState = SessionState(
                agentAssignments: template.agentAssignments,
                agentPollIntervals: template.agentPollIntervals,
                agentMaxToolCalls: template.agentMaxToolCalls,
                agentMessageDebounceIntervals: template.agentMessageDebounceIntervals,
                toolsEnabled: template.toolsEnabled,
                autoRunNextTask: template.autoRunNextTask,
                autoRunInterruptedTasks: template.autoRunInterruptedTasks
            )
            let pm = PersistenceManager(sessionID: session.id)
            do {
                try await pm.saveSessionState(inheritedState)
            } catch {
                logger.error("Failed to save inherited session state for \(session.id.uuidString): \(error.localizedDescription)")
            }
        }

        return session
    }

    /// Renames a session.
    func renameSession(id: UUID, name: String) async {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].name = name
        sessions[idx].updatedAt = Date()
        await persistSessions()
    }

    /// Closes a session: stops its runtime, removes it from the list, and deletes its
    /// on-disk data. Call only after confirming with the user — the delete is permanent.
    func closeSession(id: UUID) async {
        // Route the delete through the VM's own PersistenceManager (actor) so any pending
        // detached saves from `stopAll`'s fire-and-forget `persistMessages`/`persistTasks`
        // drain BEFORE the delete runs. Creating a fresh PM here would not serialize with
        // those pending writes, and the delete could race in between a save and its
        // implicit `ensureDirectories()` — leaving an orphan directory behind.
        let vm = viewModels[id]
        if let vm {
            await vm.stopAll()
        }
        viewModels.removeValue(forKey: id)
        sessions.removeAll { $0.id == id }

        let pm = vm?.persistenceManager ?? PersistenceManager(sessionID: id)
        do {
            try await pm.deleteSessionData()
        } catch {
            logger.error("Failed to delete session data for \(id.uuidString): \(error.localizedDescription)")
        }

        // Also delete the session's message-history UserDefaults key.
        UserDefaults.standard.removeObject(forKey: "messageHistory.\(id.uuidString)")

        await persistSessions()
    }

    /// Stops agents in every session and silences all speech (emergency-stop semantics).
    func stopAll() async {
        for vm in viewModels.values {
            await vm.stopAll()
        }
        // Silence any in-flight speech now that every session has stopped.
        shared.speechController.stopAll()
    }

    /// Is any session currently running?
    var isAnyRunning: Bool {
        viewModels.values.contains(where: \.isRunning)
    }

    /// Deletes a configuration from the shared LLM catalog AND clears any per-session
    /// assignments that reference it.
    func deleteConfiguration(id: UUID) {
        for vm in viewModels.values {
            vm.clearAssignment(forConfigID: id)
        }
        shared.deleteConfiguration(id: id)
    }

    private func persistSessions() async {
        do {
            try await shared.basePersistence.saveSessionList(sessions)
        } catch {
            logger.error("Failed to save session list: \(error.localizedDescription)")
        }
    }
}
