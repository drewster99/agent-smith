import SwiftUI

/// Primary-action toolbar for `MainView`. Renders the start/stop/reset run-control,
/// global mute, memory browser, clear-log, and inspector toggle. Pulled out of the
/// view body so the parent's modifier chain stays readable.
struct MainViewToolbar: ToolbarContent {
    @Bindable var viewModel: AppViewModel
    let shared: SharedAppState
    let onStart: () -> Void
    let onResetAndRestart: () -> Void
    let onOpenMemoryBrowser: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.isRunning {
                Button("Stop All", systemImage: "stop.circle.fill", role: .destructive) {
                    Task { await viewModel.stopAll() }
                }
                .foregroundStyle(.red)
                .keyboardShortcut("k", modifiers: [.command, .shift])
            } else if viewModel.isAborted {
                Button("Reset & Restart", systemImage: "arrow.clockwise.circle.fill",
                       action: onResetAndRestart)
                    .foregroundStyle(.orange)
            } else {
                Button("Start", systemImage: "play.circle.fill", action: onStart)
                    .foregroundStyle(.green)
            }

            if shared.speechController.isGloballyEnabled {
                Button("Mute All", systemImage: "speaker.wave.2.fill") {
                    shared.speechController.setGloballyEnabled(false)
                }
            } else {
                Button("Unmute All", systemImage: "speaker.slash.fill") {
                    shared.speechController.setGloballyEnabled(true)
                }
                .foregroundStyle(.secondary)
            }

            Button("Memory Browser", systemImage: "brain", action: onOpenMemoryBrowser)

            Button("Clear Log", systemImage: "trash") {
                viewModel.clearLog()
            }
            .disabled(viewModel.messages.isEmpty)

            Button(viewModel.showInspector ? "Hide Inspector" : "Show Inspector",
                   systemImage: "sidebar.right") {
                viewModel.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
