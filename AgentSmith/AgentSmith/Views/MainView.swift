import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Primary app view: sidebar with tasks, detail with channel log and input.
struct MainView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showValidationSheet = false
    @State private var showWelcomeSheet = false

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
                            if viewModel.allAgentConfigsValid {
                                Task { await viewModel.start() }
                            } else {
                                showValidationSheet = true
                            }
                        }
                    )
                }

                ChannelLogView(
                    messages: viewModel.messages,
                    persistedHistoryCount: viewModel.persistedHistoryCount,
                    hasRestoredHistory: viewModel.hasRestoredHistory,
                    onRestoreHistory: { viewModel.restoreHistory() }
                )

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
                    },
                    onHistoryUp: {
                        viewModel.navigateHistory(.up)
                    },
                    onHistoryDown: {
                        viewModel.navigateHistory(.down)
                    }
                )
            }
        }
        .onKeyPress(.escape) {
            guard viewModel.isRunning else { return .ignored }
            Task { await viewModel.stopCurrentTask() }
            return .handled
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
                jonesEvaluationRecords: viewModel.jonesEvaluationRecords,
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
                        if viewModel.allAgentConfigsValid {
                            Task { await viewModel.start() }
                        } else {
                            showValidationSheet = true
                        }
                    }
                    .foregroundStyle(.orange)
                } else {
                    Button("Start", systemImage: "play.circle.fill") {
                        if viewModel.allAgentConfigsValid {
                            Task { await viewModel.start() }
                        } else {
                            showValidationSheet = true
                        }
                    }
                    .foregroundStyle(.green)
                }

                if viewModel.speechController.isGloballyEnabled {
                    Button("Mute All", systemImage: "speaker.wave.2.fill") {
                        viewModel.speechController.setGloballyEnabled(false)
                    }
                } else {
                    Button("Unmute All", systemImage: "speaker.slash.fill") {
                        viewModel.speechController.setGloballyEnabled(true)
                    }
                    .foregroundStyle(.secondary)
                }

                Button("Memory Browser", systemImage: "brain") {
                    openWindow(id: "memory-browser")
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
        .onChange(of: viewModel.hasLoadedPersistedState) { _, loaded in
            guard loaded else { return }
            if viewModel.nickname.isEmpty {
                showWelcomeSheet = true
            } else if !viewModel.allAgentConfigsValid {
                showValidationSheet = true
            } else if viewModel.autoStartEnabled {
                Task { await viewModel.start() }
            }
        }
        .sheet(isPresented: $showWelcomeSheet, onDismiss: {
            if !viewModel.allAgentConfigsValid {
                showValidationSheet = true
            }
        }) {
            WelcomeSheet(viewModel: viewModel, onDismiss: {
                showWelcomeSheet = false
            })
        }
        .sheet(isPresented: $showValidationSheet) {
            ConfigValidationView(
                viewModel: viewModel,
                onStart: {
                    showValidationSheet = false
                    Task { await viewModel.start() }
                },
                onDismiss: {
                    showValidationSheet = false
                }
            )
        }
    }

}

/// Banner displayed when an agent triggers an emergency abort.
private struct AbortBanner: View {
    let reason: String
    let onReset: () -> Void

    /// Extracts the headline (e.g. "ABORT triggered by Smith") from the reason string.
    private var headline: String {
        // reason format: "ABORT triggered by <name>: <detail>"
        if let colonRange = reason.range(of: ": ") {
            return String(reason[reason.startIndex..<colonRange.lowerBound]).uppercased()
        }
        return "SYSTEM ABORT"
    }

    /// The detail portion after the headline.
    private var detail: String {
        if let colonRange = reason.range(of: ": ") {
            return String(reason[colonRange.upperBound...])
        }
        return reason
    }

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
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

/// First-launch sheet asking the user for their preferred name.
private struct WelcomeSheet: View {
    @Bindable var viewModel: AppViewModel
    let onDismiss: () -> Void
    @State private var nameInput = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("Welcome to Agent Smith")
                .font(.title2.bold())

            Text("What should I call you?")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Your name or nickname", text: $nameInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 250)
                .onSubmit { save() }

            Button("Continue") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(30)
        .frame(minWidth: 350)
    }

    private func save() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.nickname = trimmed
        viewModel.persistNickname()
        onDismiss()
    }
}
