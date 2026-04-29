import SwiftUI
import AVFoundation
import AgentSmithKit

/// Speech configuration for one agent role: voice picker + per-category speak toggles.
struct AgentConfigSpeechSection: View {
    let role: AgentRole
    let speechController: SpeechController
    let availableVoices: [AVSpeechSynthesisVoice]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech")
                .font(AppFonts.inspectorLabel.weight(.bold))
                .foregroundStyle(.secondary)

            VoicePickerRow(
                voiceIdentifier: Binding(
                    get: { speechController.agentVoiceIdentifier[role] ?? "" },
                    set: { speechController.setVoice($0, for: role) }
                ),
                availableVoices: availableVoices,
                onTest: { speechController.previewSpeech(for: role) }
            )

            ForEach(AgentSoundCategory.allCases.filter(\.supportsSpeech), id: \.self) { category in
                Toggle(
                    "Speak \(category.displayName.lowercased())",
                    isOn: Binding(
                        get: { speechController.soundConfig(for: role, category: category).speakEnabled },
                        set: { speechController.setSpeakEnabled($0, for: role, category: category) }
                    )
                )
                .font(AppFonts.inspectorBody)
            }
        }
    }
}
