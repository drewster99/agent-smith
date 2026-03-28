import SwiftUI
import AgentSmithKit

@main
struct AgentSmithApp: App {
    @State private var viewModel = AppViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            MainView(viewModel: viewModel)
                .task {
                    await viewModel.loadPersistedState()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Emergency Stop") {
                    Task { await viewModel.stopAll() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!viewModel.isRunning)
            }
            CommandGroup(after: .sidebar) {
                Button("Memory Browser") {
                    openWindow(id: "memory-browser")
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }

        WindowGroup("Agent Inspector", for: String.self) { $roleRaw in
            if let roleRaw, let role = AgentRole(rawValue: roleRaw) {
                AgentInspectorWindow(viewModel: viewModel, role: role)
            }
        }
        .defaultSize(width: 800, height: 700)

        WindowGroup("Task Detail", for: UUID.self) { $taskID in
            if let taskID, let task = viewModel.tasks.first(where: { $0.id == taskID }) {
                TaskDetailWindow(task: task)
            } else {
                ContentUnavailableView(
                    "Task Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("This task may have been deleted.")
                )
            }
        }
        .defaultSize(width: 800, height: 700)

        Window("Memory Browser", id: "memory-browser") {
            MemoryEditorView(viewModel: viewModel)
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
