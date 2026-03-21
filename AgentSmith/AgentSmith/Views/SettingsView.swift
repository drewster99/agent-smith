import AppKit
import AVFoundation
import SwiftUI
import AgentSmithKit

/// Settings window for configuring LLM endpoints per agent role and global audio.
struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Agent LLM Configuration")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Configure the LLM endpoint for each agent role. Changes take effect on next start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                AgentConfigView(
                    roleName: "Smith (Orchestrator)",
                    roleColor: AppColors.smithAgent,
                    config: $viewModel.smithConfig
                )

                AgentConfigView(
                    roleName: "Brown (Executor)",
                    roleColor: AppColors.brownAgent,
                    config: $viewModel.brownConfig
                )

                AgentConfigView(
                    roleName: "Jones (Safety Monitor)",
                    roleColor: AppColors.jonesAgent,
                    config: $viewModel.jonesConfig
                )

                Divider()
                    .padding(.vertical, 4)

                audioSettingsSection
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 600)
        .onAppear {
            availableVoices = AVSpeechSynthesisVoice.speechVoices()
                .sorted { $0.name < $1.name }
        }
        .onChange(of: viewModel.smithConfig) {
            viewModel.persistLLMConfigs()
        }
        .onChange(of: viewModel.brownConfig) {
            viewModel.persistLLMConfigs()
        }
        .onChange(of: viewModel.jonesConfig) {
            viewModel.persistLLMConfigs()
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
                }
                .padding(8)
            }

            Divider()
                .padding(.vertical, 4)

            Button("Export Current Settings as Defaults JSON\u{2026}") {
                exportDefaults()
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
    }

    private func exportDefaults() {
        let data: Data
        do {
            data = try DefaultsExporter.exportCurrentSettings(
                smithConfig: viewModel.smithConfig,
                brownConfig: viewModel.brownConfig,
                jonesConfig: viewModel.jonesConfig,
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
