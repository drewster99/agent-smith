import SwiftUI
import AgentSmithKit

@main
struct AgentSmithApp: App {
    @State private var viewModel = AppViewModel()

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
        }

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

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
