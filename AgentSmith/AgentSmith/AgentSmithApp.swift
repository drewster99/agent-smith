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
                    let focused = shared.focusedSessionID
                    Task {
                        let session = await sessionManager.createSession(templateSessionID: focused)
                        // Give the next SessionScene to appear a hint about which session to show.
                        pendingNewSessionIDs.append(session.id)
                        openWindow(id: "app-main")
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Rename Session\u{2026}") {
                    if let id = shared.focusedSessionID {
                        shared.renameSessionRequestID = id
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(shared.focusedSessionID == nil)

                Divider()

                Button("Close Session\u{2026}") {
                    if let id = shared.focusedSessionID {
                        shared.closeSessionRequestID = id
                    }
                }
                .disabled(shared.focusedSessionID == nil)
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

                Button("Timers") {
                    if let id = shared.focusedSessionID {
                        openWindow(id: "timers", value: id)
                    } else if let first = sessionManager.sessions.first {
                        openWindow(id: "timers", value: first.id)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(sessionManager.sessions.isEmpty)
            }
            CommandMenu("Debug") {
                Toggle("Show Timer Activity in Transcript", isOn: Binding(
                    get: { shared.showTimerActivityInTranscript },
                    set: { shared.showTimerActivityInTranscript = $0 }
                ))
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

        WindowGroup("Timers", id: "timers", for: UUID.self) { $sessionID in
            if let id = sessionID, let vm = sessionManager.viewModel(for: id) {
                TimersWindow(viewModel: vm)
            } else {
                ContentUnavailableView(
                    "Session Closed",
                    systemImage: "clock.badge.exclamationmark",
                    description: Text("Open a session and try again.")
                )
            }
        }
        .defaultSize(width: 720, height: 520)

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
    @Bindable var shared: SharedAppState
    @Bindable var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow

    @SceneStorage("sessionID") private var sessionIDString: String = ""
    @State private var bootstrapped = false
    @State private var showCloseConfirm = false
    @State private var showRenameSheet = false
    @State private var renameDraft = ""

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
        .background(WindowKeyObserver(sessionID: resolvedID, shared: shared))
        .onChange(of: shared.closeSessionRequestID) { _, newValue in
            guard let id = newValue, id == resolvedID else { return }
            shared.closeSessionRequestID = nil
            showCloseConfirm = true
        }
        .onChange(of: shared.renameSessionRequestID) { _, newValue in
            guard let id = newValue, id == resolvedID,
                  let session = sessionManager.sessions.first(where: { $0.id == id }) else {
                return
            }
            shared.renameSessionRequestID = nil
            renameDraft = session.name
            showRenameSheet = true
        }
        .confirmationDialog(
            "Close this session?",
            isPresented: $showCloseConfirm,
            titleVisibility: .visible,
            actions: {
                Button("Close Session", role: .destructive, action: {
                    if let id = resolvedID {
                        Task { await closeAndDropScene(id: id) }
                    }
                })
                Button("Cancel", role: .cancel, action: {})
            },
            message: {
                if let id = resolvedID, let s = sessionManager.sessions.first(where: { $0.id == id }) {
                    Text("“\(s.name)” will be removed and its channel log, tasks, and attachments deleted from disk. This cannot be undone.")
                } else {
                    Text("This session will be removed and its data deleted from disk. This cannot be undone.")
                }
            }
        )
        .sheet(isPresented: $showRenameSheet) {
            RenameSessionSheet(
                name: $renameDraft,
                onCommit: {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, let id = resolvedID else {
                        showRenameSheet = false
                        return
                    }
                    Task { await sessionManager.renameSession(id: id, name: trimmed) }
                    showRenameSheet = false
                },
                onCancel: { showRenameSheet = false }
            )
        }
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
        let session = await sessionManager.createSession(templateSessionID: shared.focusedSessionID)
        sessionIDString = session.id.uuidString
    }

    /// Deletes the session's on-disk data and the SessionManager entry, then clears this
    /// scene's stored ID so the view flips to the "No Session" placeholder. The window
    /// itself stays open — the user can pick New Session or close the tab natively.
    private func closeAndDropScene(id: UUID) async {
        await sessionManager.closeSession(id: id)
        sessionIDString = ""
        if shared.focusedSessionID == id {
            shared.focusedSessionID = nil
        }
    }
}

/// Observes the containing NSWindow's key state and publishes the session ID as
/// `shared.focusedSessionID` so menu commands can target the frontmost tab.
private struct WindowKeyObserver: NSViewRepresentable {
    let sessionID: UUID?
    let shared: SharedAppState

    func makeNSView(context: Context) -> NSView {
        let view = KeyTrackingView()
        view.sessionID = sessionID
        view.shared = shared
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyTrackingView else { return }
        view.sessionID = sessionID
        view.shared = shared
        // If this view is currently inside the key window and the effective focused ID
        // differs, republish it. Guarded equality avoids spamming @Observable notifications
        // (which would invalidate any view reading `focusedSessionID`) on every update pass.
        if let window = view.window, window.isKeyWindow, let id = sessionID,
           shared.focusedSessionID != id {
            shared.focusedSessionID = id
        }
    }

    @MainActor
    private final class KeyTrackingView: NSView {
        var sessionID: UUID?
        weak var shared: SharedAppState?
        private var keyObserver: NSObjectProtocol?
        private var resignObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            keyObserver = nil
            resignObserver = nil
            guard let window else { return }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let id = self.sessionID else { return }
                    self.shared?.focusedSessionID = id
                }
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Clear only if the focused ID still points at us; another window
                    // may already have claimed focus via didBecomeKeyNotification.
                    if self.shared?.focusedSessionID == self.sessionID {
                        self.shared?.focusedSessionID = nil
                    }
                }
            }
            if window.isKeyWindow, let id = sessionID {
                shared?.focusedSessionID = id
            }
        }

        isolated deinit {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
        }
    }
}

/// Small sheet used by Rename Session.
private struct RenameSessionSheet: View {
    @Binding var name: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.title2.bold())
            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .onSubmit(onCommit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
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
