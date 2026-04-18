import SwiftUI
import AppKit
import AgentSmithKit

@main
struct AgentSmithApp: App {
    @State private var shared: SharedAppState
    @State private var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow

    init() {
        let sharedState = SharedAppState()
        _shared = State(initialValue: sharedState)
        _sessionManager = State(initialValue: SessionManager(shared: sharedState))
        // Enable native NSWindow tabbing so multiple session windows auto-tab (and can be
        // dragged out to detach).
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    var body: some Scene {
        WindowGroup(id: "app-main") {
            SessionScene(shared: shared, sessionManager: sessionManager)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    Task {
                        let session = await sessionManager.createSession()
                        // Give the next SessionScene to appear a hint about which session to show.
                        pendingNewSessionIDs.append(session.id)
                        openWindow(id: "app-main")
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Emergency Stop") {
                    Task { await sessionManager.stopAll() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!sessionManager.isAnyRunning)
            }
            CommandGroup(after: .sidebar) {
                Button("Memory Browser") {
                    openWindow(id: "memory-browser")
                }
                .keyboardShortcut("m", modifiers: [.command, .option])

                Button("Spending Dashboard") {
                    openWindow(id: "spending-dashboard")
                }
                .keyboardShortcut("4", modifiers: .command)
            }
        }

        WindowGroup("Agent Inspector", for: AgentInspectorTarget.self) { $target in
            if let target, let vm = sessionManager.viewModel(for: target.sessionID) {
                AgentInspectorWindow(viewModel: vm, role: target.role)
            } else {
                ContentUnavailableView(
                    "Agent Inspector Unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("The session for this inspector is no longer open.")
                )
            }
        }
        .defaultSize(width: 800, height: 700)

        WindowGroup("Task Detail", for: TaskDetailTarget.self) { $target in
            if let target, let vm = sessionManager.viewModel(for: target.sessionID) {
                TaskDetailWindow(taskID: target.taskID, viewModel: vm)
            } else {
                ContentUnavailableView(
                    "Task Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("This task's session may have been closed.")
                )
            }
        }
        .defaultSize(width: 800, height: 700)

        Window("Memory Browser", id: "memory-browser") {
            MemoryEditorView(shared: shared)
        }
        .defaultSize(width: 900, height: 600)

        Window("Spending Dashboard", id: "spending-dashboard") {
            SpendingDashboardView(shared: shared)
        }
        .defaultSize(width: 900, height: 800)

        Settings {
            SettingsView(shared: shared, sessionManager: sessionManager)
        }
    }
}

/// Cross-scene handoff queue for "which session should the next fresh window adopt?".
/// Commands don't have direct access to @SceneStorage, so we stash intended sessions
/// in this FIFO queue; each SessionScene that appears with empty storage consumes the
/// head. A queue (not a single value) prevents two rapid Cmd+Ns from clobbering each
/// other's handoff. @MainActor because it's only read/written from main-actor SwiftUI code.
@MainActor private var pendingNewSessionIDs: [UUID] = []

/// Container view that resolves the per-session view model and renders MainView.
///
/// Uses `@SceneStorage` so each window "remembers" which session it's showing across
/// app restarts (macOS handles scene restoration for WindowGroups automatically).
struct SessionScene: View {
    let shared: SharedAppState
    @Bindable var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow

    @SceneStorage("sessionID") private var sessionIDString: String = ""
    @State private var bootstrapped = false

    var body: some View {
        Group {
            if !shared.hasLoadedPersistedState || !bootstrapped {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let id = resolvedID, let vm = sessionManager.viewModel(for: id) {
                MainView(viewModel: vm, sessionManager: sessionManager)
                    .navigationTitle(vm.session.name)
            } else {
                ContentUnavailableView {
                    Label("No Session", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("This session has been closed. Open a new one to continue.")
                } actions: {
                    Button("New Session") {
                        Task { await createAndAdoptSession() }
                    }
                }
            }
        }
        .task { await bootstrapIfNeeded() }
    }

    private var resolvedID: UUID? {
        guard let uuid = UUID(uuidString: sessionIDString) else { return nil }
        return sessionManager.sessions.contains(where: { $0.id == uuid }) ? uuid : nil
    }

    private func bootstrapIfNeeded() async {
        // Both calls are idempotent — the first window's invocation does the work;
        // concurrent windows await the same Task and then return.
        await shared.loadPersistedState()
        await sessionManager.loadSessions()

        // If the command-triggered path stashed session IDs, adopt the next one.
        if sessionIDString.isEmpty, !pendingNewSessionIDs.isEmpty {
            let pending = pendingNewSessionIDs.removeFirst()
            if sessionManager.sessions.contains(where: { $0.id == pending }) {
                sessionIDString = pending.uuidString
            }
        }

        // If no valid session ID is set for this window, pick one.
        if resolvedID == nil {
            if let first = sessionManager.sessions.first {
                sessionIDString = first.id.uuidString
            } else {
                let session = await sessionManager.createSession(name: "Default")
                sessionIDString = session.id.uuidString
            }
        }

        bootstrapped = true
    }

    private func createAndAdoptSession() async {
        let session = await sessionManager.createSession()
        sessionIDString = session.id.uuidString
    }
}

/// Identifies an Agent Inspector window instance by session + role.
struct AgentInspectorTarget: Codable, Hashable, Sendable {
    let sessionID: UUID
    let role: AgentRole
}

/// Identifies a Task Detail window instance by session + task ID.
struct TaskDetailTarget: Codable, Hashable, Sendable {
    let sessionID: UUID
    let taskID: UUID
}
