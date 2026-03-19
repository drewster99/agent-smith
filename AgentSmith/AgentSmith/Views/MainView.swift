import SwiftUI
import AgentSmithKit

/// Primary app view: sidebar with tasks, detail with channel log and input.
struct MainView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tasks")
                    .font(AppFonts.sectionHeader)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                ScrollView {
                    TaskListView(viewModel: viewModel)
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                if viewModel.isAborted {
                    AbortBanner(
                        reason: viewModel.abortReason,
                        onReset: {
                            viewModel.resetAbort()
                            Task { await viewModel.start() }
                        }
                    )
                }

                ChannelLogView(messages: viewModel.messages)

                Divider()

                UserInputView(
                    text: $viewModel.inputText,
                    pendingAttachments: viewModel.pendingAttachments,
                    isRunning: viewModel.isRunning,
                    onSend: {
                        Task { await viewModel.sendMessage() }
                    },
                    onAttach: { urls in
                        viewModel.addAttachments(from: urls)
                    },
                    onRemoveAttachment: { id in
                        viewModel.removePendingAttachment(id: id)
                    }
                )
            }
        }
        .inspector(isPresented: $viewModel.showInspector) {
            InspectorView(
                messages: viewModel.messages,
                processingRoles: viewModel.processingRoles,
                agentToolNames: viewModel.agentToolNames,
                agentContexts: viewModel.agentContexts,
                agentTurns: viewModel.agentTurns,
                agentPollIntervals: viewModel.agentPollIntervals,
                agentMaxToolCalls: viewModel.agentMaxToolCalls,
                speechController: viewModel.speechController,
                onSendDirectMessage: { role, text in
                    Task { await viewModel.sendDirectMessage(to: role, text: text) }
                },
                onUpdateSystemPrompt: { role, prompt in
                    Task { await viewModel.updateSystemPrompt(for: role, prompt: prompt) }
                },
                onUpdatePollInterval: { role, interval in
                    Task { await viewModel.updatePollInterval(for: role, interval: interval) }
                },
                onUpdateMaxToolCalls: { role, count in
                    Task { await viewModel.updateMaxToolCalls(for: role, count: count) }
                }
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isRunning {
                    Button("Stop All", systemImage: "stop.circle.fill", role: .destructive) {
                        Task { await viewModel.stopAll() }
                    }
                    .foregroundStyle(.red)
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                } else if viewModel.isAborted {
                    Button("Reset & Restart", systemImage: "arrow.clockwise.circle.fill") {
                        viewModel.resetAbort()
                        Task { await viewModel.start() }
                    }
                    .foregroundStyle(.orange)
                } else {
                    Button("Start", systemImage: "play.circle.fill") {
                        Task { await viewModel.start() }
                    }
                    .foregroundStyle(.green)
                }

                if viewModel.speechController.isGloballyEnabled {
                    Button("Mute All", systemImage: "speaker.slash.fill") {
                        viewModel.speechController.setGloballyEnabled(false)
                    }
                } else {
                    Button("Unmute All", systemImage: "speaker.wave.2.fill") {
                        viewModel.speechController.setGloballyEnabled(true)
                    }
                    .foregroundStyle(.secondary)
                }

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
        .navigationTitle("Agent Smith")
    }
}

/// Banner displayed when Jones triggers an emergency abort.
private struct AbortBanner: View {
    let reason: String
    let onReset: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("SYSTEM ABORTED BY JONES")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            Button("Reset & Restart", action: onReset)
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(10)
        .background(.red.gradient)
    }
}
