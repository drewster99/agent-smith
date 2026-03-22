import AppKit
import AVFoundation
import SwiftUI
import AgentSmithKit
import SwiftLLMKit

/// Settings window organized into tabs: Providers, Model Configurations, Agent Assignments, Audio.
struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @State private var exportError: String?

    var body: some View {
        TabView {
            Tab("Providers", systemImage: "server.rack") {
                ScrollView {
                    ProviderManagementView(llmKit: viewModel.llmKit)
                        .padding()
                }
            }

            Tab("Configurations", systemImage: "slider.horizontal.3") {
                ScrollView {
                    configurationsTab
                        .padding()
                }
            }

            Tab("Agents", systemImage: "person.3") {
                ScrollView {
                    agentAssignmentsTab
                        .padding()
                }
            }

            Tab("Audio", systemImage: "speaker.wave.2") {
                ScrollView {
                    audioSettingsSection
                        .padding()
                }
            }
        }
        .frame(minWidth: 550, minHeight: 600)
        .onAppear {
            availableVoices = AVSpeechSynthesisVoice.speechVoices()
                .sorted { $0.name < $1.name }
        }
        .onChange(of: viewModel.agentAssignments) {
            viewModel.persistAgentAssignments()
        }
    }

    // MARK: - Configurations Tab

    @State private var editingConfig: ModelConfiguration?
    @State private var isCreatingConfig = false

    private var configurationsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model Configurations")
                    .font(AppFonts.sectionHeader)
                Spacer()
                Button(action: { isCreatingConfig = true }, label: {
                    Label("New Configuration", systemImage: "plus")
                })
            }

            if viewModel.llmKit.configurations.isEmpty {
                Text("No configurations yet. Create one to assign to agents.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(viewModel.llmKit.configurations) { config in
                    configRow(config)
                }
            }

            Divider().padding(.vertical, 4)

            HStack {
                Button("Refresh Models") {
                    Task { await viewModel.llmKit.forceRefresh() }
                }
                .disabled(viewModel.llmKit.isRefreshing)
                if viewModel.llmKit.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Export Current Settings as Defaults JSON\u{2026}") {
                    exportDefaults()
                }
            }
        }
        .sheet(isPresented: $isCreatingConfig) {
            ModelConfigurationEditorView(
                llmKit: viewModel.llmKit,
                existingConfig: nil,
                onSave: { config in
                    viewModel.llmKit.addConfiguration(config)
                },
                onDismiss: { isCreatingConfig = false }
            )
        }
        .sheet(item: $editingConfig) { config in
            ModelConfigurationEditorView(
                llmKit: viewModel.llmKit,
                existingConfig: config,
                onSave: { updated in
                    viewModel.llmKit.updateConfiguration(updated)
                },
                onDismiss: { editingConfig = nil }
            )
        }
        .alert("Export Error", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        ), actions: {
            Button("OK") { exportError = nil }
        }, message: {
            Text(exportError ?? "")
        })
    }

    private func configRow(_ config: ModelConfiguration) -> some View {
        let provider = viewModel.llmKit.providers.first { $0.id == config.providerID }
        return GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(config.name)
                            .font(.headline)
                        if !config.isValid {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(config.validationError ?? "Invalid configuration")
                        }
                    }
                    HStack(spacing: 8) {
                        if let provider {
                            Text(provider.name)
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(config.modelID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("temp \(String(format: "%.1f", config.temperature))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("max \(formatTokenCount(config.maxOutputTokens))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let budget = config.thinkingBudget, budget > 0 {
                            Text("think \(formatTokenCount(budget))")
                                .font(.caption)
                                .foregroundStyle(.purple)
                        }
                    }
                }
                Spacer()
                Button("Duplicate") {
                    viewModel.llmKit.duplicateConfiguration(id: config.id)
                }
                .buttonStyle(.borderless)
                Button("Edit") {
                    editingConfig = config
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: {
                    viewModel.llmKit.deleteConfiguration(id: config.id)
                }, label: {
                    Image(systemName: "trash")
                })
                .buttonStyle(.borderless)
            }
            .padding(4)
        }
    }

    // MARK: - Agent Assignments Tab

    private var agentAssignmentsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Assignments")
                .font(AppFonts.sectionHeader)

            Text("Assign a model configuration to each agent role. Changes take effect on next start.")
                .font(.callout)
                .foregroundStyle(.secondary)

            agentAssignmentRow(
                role: .smith,
                label: "Smith (Orchestrator)",
                color: AppColors.smithAgent
            )
            agentAssignmentRow(
                role: .brown,
                label: "Brown (Executor)",
                color: AppColors.brownAgent
            )
            agentAssignmentRow(
                role: .jones,
                label: "Jones (Safety Monitor)",
                color: AppColors.jonesAgent
            )
        }
    }

    private func agentAssignmentRow(role: AgentRole, label: String, color: Color) -> some View {
        let currentConfigID = viewModel.agentAssignments[role]
        let currentConfig = currentConfigID.flatMap { id in
            viewModel.llmKit.configurations.first { $0.id == id }
        }

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(label, systemImage: "person.circle")
                    .font(AppFonts.sectionHeader)
                    .foregroundStyle(color)

                HStack {
                    Picker("Configuration", selection: Binding(
                        get: { viewModel.agentAssignments[role] ?? UUID() },
                        set: { viewModel.agentAssignments[role] = $0 }
                    )) {
                        Text("None").tag(UUID())
                        ForEach(viewModel.llmKit.configurations) { config in
                            HStack {
                                Text(config.name)
                                if !config.isValid {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                }
                            }
                            .tag(config.id)
                        }
                    }
                    .labelsHidden()

                    if let config = currentConfig, !config.isValid {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(config.validationError ?? "Invalid")
                    }
                }

                if let config = currentConfig {
                    HStack(spacing: 8) {
                        Text(config.modelID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("temp \(String(format: "%.1f", config.temperature))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("max \(formatTokenCount(config.maxOutputTokens))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Audio settings

    private var audioSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Settings")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            // User
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("User", systemImage: "person.circle")
                        .font(AppFonts.sectionHeader)
                        .foregroundStyle(.blue)

                    VoicePickerRow(
                        voiceIdentifier: Binding(
                            get: { viewModel.speechController.userVoiceIdentifier },
                            set: { viewModel.speechController.setUserVoice($0) }
                        ),
                        availableVoices: availableVoices,
                        onTest: { viewModel.speechController.previewUserSpeech() }
                    )

                    SoundPickerRow(
                        label: "Message sound",
                        soundName: Binding(
                            get: { viewModel.speechController.userSound.soundName },
                            set: {
                                var config = viewModel.speechController.userSound
                                config.soundName = $0
                                viewModel.speechController.setUserSound(config)
                            }
                        ),
                        onPreview: { viewModel.speechController.previewSound(named: $0) }
                    )

                    Toggle("Speak user messages", isOn: Binding(
                        get: { viewModel.speechController.userSound.speakEnabled },
                        set: {
                            var config = viewModel.speechController.userSound
                            config.speakEnabled = $0
                            viewModel.speechController.setUserSound(config)
                        }
                    ))
                    .font(AppFonts.inspectorBody)
                }
                .padding(8)
            }

            // Narrator
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Narrator", systemImage: "text.bubble")
                        .font(AppFonts.sectionHeader)
                        .foregroundStyle(.purple)

                    Toggle("Enabled", isOn: Binding(
                        get: { viewModel.speechController.narratorEnabled },
                        set: { viewModel.speechController.setNarratorEnabled($0) }
                    ))

                    VoicePickerRow(
                        voiceIdentifier: Binding(
                            get: { viewModel.speechController.narratorVoiceIdentifier },
                            set: { viewModel.speechController.setNarratorVoice($0) }
                        ),
                        availableVoices: availableVoices,
                        onTest: { viewModel.speechController.previewNarratorSpeech() }
                    )
                }
                .padding(8)
            }

            // Security sounds
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Review Sounds", systemImage: "shield.lefthalf.filled")
                        .font(AppFonts.sectionHeader)
                        .foregroundStyle(.orange)

                    SoundPickerRow(
                        label: "Approved",
                        soundName: Binding(
                            get: { viewModel.speechController.securitySafeSoundName },
                            set: { viewModel.speechController.setSecuritySafeSound($0) }
                        ),
                        onPreview: { viewModel.speechController.previewSound(named: $0) }
                    )

                    SoundPickerRow(
                        label: "Warning",
                        soundName: Binding(
                            get: { viewModel.speechController.securityWarnSoundName },
                            set: { viewModel.speechController.setSecurityWarnSound($0) }
                        ),
                        onPreview: { viewModel.speechController.previewSound(named: $0) }
                    )

                    SoundPickerRow(
                        label: "Denied",
                        soundName: Binding(
                            get: { viewModel.speechController.securityDenySoundName },
                            set: { viewModel.speechController.setSecurityDenySound($0) }
                        ),
                        onPreview: { viewModel.speechController.previewSound(named: $0) }
                    )

                    SoundPickerRow(
                        label: "Abort",
                        soundName: Binding(
                            get: { viewModel.speechController.securityAbortSoundName },
                            set: { viewModel.speechController.setSecurityAbortSound($0) }
                        ),
                        onPreview: { viewModel.speechController.previewSound(named: $0) }
                    )
                }
                .padding(8)
            }
        }
    }

    private func exportDefaults() {
        let data: Data
        do {
            data = try DefaultsExporter.exportCurrentSettings(
                llmKit: viewModel.llmKit,
                agentAssignments: viewModel.agentAssignments,
                pollIntervals: viewModel.agentPollIntervals,
                maxToolCalls: viewModel.agentMaxToolCalls,
                messageDebounceIntervals: viewModel.agentMessageDebounceIntervals,
                speechController: viewModel.speechController
            )
        } catch {
            exportError = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "defaults.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = "Failed to write file: \(error.localizedDescription)"
        }
    }
}
