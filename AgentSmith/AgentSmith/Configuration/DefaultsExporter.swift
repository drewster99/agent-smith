import Foundation
import AgentSmithKit

/// Builds an `AppDefaults` from live application state and encodes it to pretty-printed JSON.
enum DefaultsExporter {
    /// Constructs an `AppDefaults` snapshot from the current runtime configuration.
    ///
    /// - Parameters:
    ///   - smithConfig: Current LLM configuration for the Smith agent.
    ///   - brownConfig: Current LLM configuration for the Brown agent.
    ///   - jonesConfig: Current LLM configuration for the Jones agent.
    ///   - pollIntervals: Current poll intervals keyed by role.
    ///   - maxToolCalls: Current max tool-calls-per-response keyed by role.
    ///   - messageDebounceIntervals: Current message debounce intervals keyed by role.
    ///   - speechController: The live `SpeechController` whose properties are read.
    /// - Returns: Pretty-printed JSON `Data` representing the full `AppDefaults`.
    @MainActor
    static func exportCurrentSettings(
        smithConfig: LLMConfiguration,
        brownConfig: LLMConfiguration,
        jonesConfig: LLMConfiguration,
        pollIntervals: [AgentRole: TimeInterval],
        maxToolCalls: [AgentRole: Int],
        messageDebounceIntervals: [AgentRole: TimeInterval],
        speechController: SpeechController
    ) throws -> Data {
        let llmConfigs: [AgentRole: LLMConfiguration] = [
            .smith: smithConfig,
            .brown: brownConfig,
            .jones: jonesConfig
        ]

        var agentTuning: [AgentRole: AgentTuningDefaults] = [:]
        for role in AgentRole.allCases {
            agentTuning[role] = AgentTuningDefaults(
                pollInterval: pollIntervals[role] ?? 5,
                maxToolCalls: maxToolCalls[role] ?? 100,
                messageDebounceInterval: messageDebounceIntervals[role] ?? 1
            )
        }

        var agentSpeechDefaults: [AgentRole: AgentSpeechDefaults] = [:]
        for role in AgentRole.allCases {
            var categories: [String: SoundConfigDefaults] = [:]
            for category in AgentSoundCategory.allCases {
                let config = speechController.soundConfig(for: role, category: category)
                categories[category.storageKey] = SoundConfigDefaults(
                    soundName: config.soundName,
                    speakEnabled: config.speakEnabled
                )
            }
            agentSpeechDefaults[role] = AgentSpeechDefaults(
                enabled: speechController.agentEnabled[role] ?? false,
                voiceIdentifier: speechController.agentVoiceIdentifier[role] ?? "",
                categories: categories
            )
        }

        let speech = SpeechDefaults(
            globalEnabled: speechController.isGloballyEnabled,
            agents: agentSpeechDefaults,
            user: UserSpeechDefaults(
                soundName: speechController.userSound.soundName,
                speakEnabled: speechController.userSound.speakEnabled,
                voiceIdentifier: speechController.userVoiceIdentifier
            ),
            narrator: NarratorDefaults(
                enabled: speechController.narratorEnabled,
                voiceIdentifier: speechController.narratorVoiceIdentifier
            ),
            security: SecuritySoundDefaults(
                safeSoundName: speechController.securitySafeSoundName,
                warnSoundName: speechController.securityWarnSoundName,
                denySoundName: speechController.securityDenySoundName
            )
        )

        let appDefaults = AppDefaults(
            llmConfigs: llmConfigs,
            agentTuning: agentTuning,
            speech: speech
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(appDefaults)
    }
}
