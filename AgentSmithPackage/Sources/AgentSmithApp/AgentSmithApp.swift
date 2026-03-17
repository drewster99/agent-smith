import SwiftUI

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

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
