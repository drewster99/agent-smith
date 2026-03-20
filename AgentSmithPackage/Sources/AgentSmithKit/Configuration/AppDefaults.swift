import Foundation

/// Top-level Codable struct representing the bundled `defaults.json` schema.
///
/// Every field provides a default value for the application. UserDefaults entries
/// (set by the user in the UI) always take precedence over these values.
public struct AppDefaults: Codable, Sendable {
    /// Schema version — bump when the JSON format changes.
    public var version: Int = 1
    /// Per-role LLM endpoint configurations.
    public var llmConfigs: [AgentRole: LLMConfiguration]
    /// Per-role agent tuning parameters (poll intervals, tool-call limits, etc.).
    public var agentTuning: [AgentRole: AgentTuningDefaults]
    /// Speech and sound configuration.
    public var speech: SpeechDefaults

    public init(
        version: Int = 1,
        llmConfigs: [AgentRole: LLMConfiguration],
        agentTuning: [AgentRole: AgentTuningDefaults],
        speech: SpeechDefaults
    ) {
        self.version = version
        self.llmConfigs = llmConfigs
        self.agentTuning = agentTuning
        self.speech = speech
    }
}

/// Per-agent tuning parameters that affect the agent's run loop timing.
public struct AgentTuningDefaults: Codable, Sendable {
    /// Seconds between idle poll cycles.
    public var pollInterval: TimeInterval
    /// Maximum tool calls the agent will execute per LLM response.
    public var maxToolCalls: Int
    /// Seconds of channel silence required before processing batched messages.
    public var messageDebounceInterval: TimeInterval

    public init(
        pollInterval: TimeInterval,
        maxToolCalls: Int,
        messageDebounceInterval: TimeInterval
    ) {
        self.pollInterval = pollInterval
        self.maxToolCalls = maxToolCalls
        self.messageDebounceInterval = messageDebounceInterval
    }
}

/// Sound and speech defaults for the entire application.
public struct SpeechDefaults: Codable, Sendable {
    /// Whether sound/speech is globally enabled.
    public var globalEnabled: Bool
    /// Per-agent sound/speech settings keyed by role.
    public var agents: [AgentRole: AgentSpeechDefaults]
    /// User message sound/speech settings.
    public var user: UserSpeechDefaults
    /// Narrator voice settings.
    public var narrator: NarratorDefaults
    /// Security review sounds.
    public var security: SecuritySoundDefaults

    public init(
        globalEnabled: Bool,
        agents: [AgentRole: AgentSpeechDefaults],
        user: UserSpeechDefaults,
        narrator: NarratorDefaults,
        security: SecuritySoundDefaults
    ) {
        self.globalEnabled = globalEnabled
        self.agents = agents
        self.user = user
        self.narrator = narrator
        self.security = security
    }
}

/// Per-agent speech and sound configuration.
public struct AgentSpeechDefaults: Codable, Sendable {
    /// Whether speech is enabled for this agent.
    public var enabled: Bool
    /// The voice identifier string for this agent's speech synthesis.
    public var voiceIdentifier: String
    /// Sound/speech config per category. Keys are `AgentSoundCategory` storage keys
    /// (e.g. `"toUser"`, `"toAgent"`, `"public"`, `"tool"`, `"error"`).
    public var categories: [String: SoundConfigDefaults]

    public init(
        enabled: Bool,
        voiceIdentifier: String,
        categories: [String: SoundConfigDefaults]
    ) {
        self.enabled = enabled
        self.voiceIdentifier = voiceIdentifier
        self.categories = categories
    }
}

/// Sound + speech-enable pair for a single message category.
public struct SoundConfigDefaults: Codable, Sendable {
    /// System sound name, or empty string for none.
    public var soundName: String
    /// Whether text-to-speech is enabled for this category.
    public var speakEnabled: Bool

    public init(soundName: String, speakEnabled: Bool) {
        self.soundName = soundName
        self.speakEnabled = speakEnabled
    }
}

/// User message sound/speech settings.
public struct UserSpeechDefaults: Codable, Sendable {
    /// System sound name for user messages.
    public var soundName: String
    /// Whether text-to-speech is enabled for user messages.
    public var speakEnabled: Bool
    /// Voice identifier for user speech synthesis.
    public var voiceIdentifier: String

    public init(soundName: String, speakEnabled: Bool, voiceIdentifier: String) {
        self.soundName = soundName
        self.speakEnabled = speakEnabled
        self.voiceIdentifier = voiceIdentifier
    }
}

/// Narrator voice configuration.
public struct NarratorDefaults: Codable, Sendable {
    /// Whether narrator speech is enabled.
    public var enabled: Bool
    /// Voice identifier for narrator speech synthesis.
    public var voiceIdentifier: String

    public init(enabled: Bool, voiceIdentifier: String) {
        self.enabled = enabled
        self.voiceIdentifier = voiceIdentifier
    }
}

/// Security review sound configuration.
public struct SecuritySoundDefaults: Codable, Sendable {
    /// Sound name for approved tool requests.
    public var safeSoundName: String
    /// Sound name for approved-with-warning tool requests.
    public var warnSoundName: String
    /// Sound name for denied tool requests.
    public var denySoundName: String

    public init(safeSoundName: String, warnSoundName: String, denySoundName: String) {
        self.safeSoundName = safeSoundName
        self.warnSoundName = warnSoundName
        self.denySoundName = denySoundName
    }
}
