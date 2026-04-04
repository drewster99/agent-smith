import SwiftUI
import SwiftLLMKit
import AgentSmithKit
import UniformTypeIdentifiers

/// Primary app view: sidebar with tasks, detail with channel log and input.
struct MainView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showValidationSheet = false
    @State private var showWelcomeSheet = false
    @State private var isDropTargeted = false
    /// The attachment currently shown in the full-screen image viewer.
    @State private var selectedImageAttachment: Attachment?
    @FocusState private var isLightboxFocused: Bool

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tasks")
                    .font(AppFonts.sectionHeader)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Toggle("Auto-run next task", isOn: Binding(
                    get: { viewModel.autoRunNextTask },
                    set: { viewModel.autoRunNextTask = $0 }
                ))
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

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

                if let reviewTask = viewModel.taskAwaitingReview {
                    ReviewBanner(taskTitle: reviewTask.title)
                }

                ChannelLogView(
                    messages: viewModel.messages,
                    persistedHistoryCount: viewModel.persistedHistoryCount,
                    hasRestoredHistory: viewModel.hasRestoredHistory,
                    onRestoreHistory: { viewModel.restoreHistory() },
                    selectedImageAttachment: $selectedImageAttachment
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
                    },
                    onPaste: {
                        viewModel.pasteFromClipboard()
                    }
                )
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.blue, lineWidth: 3)
                        .background(.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if let attachment = selectedImageAttachment {
                    ImageLightbox(attachment: attachment, onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedImageAttachment = nil
                        }
                    })
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isLightboxFocused)
                    .onAppear { isLightboxFocused = true }
                    .onKeyPress(.escape) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedImageAttachment = nil
                        }
                        return .handled
                    }
                }
            }
        }
        .onKeyPress(.escape) {
            guard viewModel.isRunning else { return .ignored }
            Task { await viewModel.stopCurrentTask() }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "l"), phases: .down) { keyPress in
            guard keyPress.modifiers == .control else { return .ignored }
            viewModel.clearLog()
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
                agentModelConfigs: viewModel.resolvedAgentConfigs,
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

    /// Processes dropped items from a drag-and-drop operation.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            // File URLs (covers any file type dragged from Finder)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    if let error {
                        print("[AgentSmith] Drop: failed to load file URL: \(error)")
                        return
                    }
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        print("[AgentSmith] Drop: could not decode file URL from dropped item")
                        return
                    }
                    Task { @MainActor in
                        viewModel.addAttachments(from: [url])
                    }
                }
            }
            // Raw image data (covers dragging images from browsers, etc.)
            else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    if let error {
                        print("[AgentSmith] Drop: failed to load image data: \(error)")
                        return
                    }
                    guard let data else {
                        print("[AgentSmith] Drop: image provider returned nil data")
                        return
                    }
                    // Convert to PNG for consistency
                    let pngData: Data
                    if let bitmap = NSBitmapImageRep(data: data),
                       let converted = bitmap.representation(using: .png, properties: [:]) {
                        pngData = converted
                    } else {
                        pngData = data
                    }
                    Task { @MainActor in
                        viewModel.addAttachment(
                            data: pngData,
                            filename: "Dropped Image \(AppViewModel.attachmentTimestamp()).png",
                            mimeType: "image/png"
                        )
                    }
                }
            }
        }
        return handled
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

/// Small banner shown when a task is awaiting Smith's review.
private struct ReviewBanner: View {
    let taskTitle: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.circle.fill")
                .foregroundStyle(.orange)
            Text("Awaiting review:")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text(taskTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
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
