import SwiftUI
import AgentSmithKit

/// Sound-effect picker for every `AgentSoundCategory` in one agent's config.
struct AgentConfigSoundsSection: View {
    let role: AgentRole
    let speechController: SpeechController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sounds")
                .font(AppFonts.inspectorLabel.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(AgentSoundCategory.allCases, id: \.self) { category in
                SoundPickerRow(
                    label: category.displayName,
                    soundName: Binding(
                        get: { speechController.soundConfig(for: role, category: category).soundName },
                        set: { speechController.setSoundName($0, for: role, category: category) }
                    ),
                    onPreview: { speechController.previewSound(named: $0) }
                )
            }
        }
    }
}
