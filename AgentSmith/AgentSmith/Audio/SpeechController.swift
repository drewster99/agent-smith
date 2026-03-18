import AVFoundation
import AppKit
import AgentSmithKit

/// Manages per-agent text-to-speech synthesis and notification sounds.
///
/// Each agent gets its own `AVSpeechSynthesizer` so their utterances queue independently —
/// one agent's speech never cancels another's. Turning off global or per-agent speech
/// immediately stops any in-progress utterances for the affected synthesizer(s).
@Observable
@MainActor
final class SpeechController {

    // MARK: - Static config

    /// System sound names available for agent notifications.
    static let systemSoundNames: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    // MARK: - State

    var isGloballyEnabled: Bool = false
    var agentEnabled: [AgentRole: Bool] = [:]
    var agentVoiceIdentifier: [AgentRole: String] = [:]    // "" = system default
    var agentMessageSoundName: [AgentRole: String] = [:]   // "" = none
    var agentToolSoundName: [AgentRole: String] = [:]      // "" = none

    // MARK: - Private

    private var synthesizers: [AgentRole: AVSpeechSynthesizer] = [:]

    // MARK: - Init

    init() {
        for role in AgentRole.allCases {
            synthesizers[role] = AVSpeechSynthesizer()
        }
        loadSettings()
    }

    // MARK: - Public interface

    /// Call for each incoming channel message. Speaks text and/or plays sounds per agent config.
    func handle(_ message: ChannelMessage) {
        guard isGloballyEnabled else { return }
        guard case .agent(let role) = message.sender else { return }
        guard agentEnabled[role] == true else { return }

        let isToolRelated: Bool
        if message.metadata?["tool"] != nil {
            isToolRelated = true
        } else if let mv = message.metadata?["messageKind"], case .string(let kind) = mv {
            isToolRelated = kind == "tool_request"
        } else {
            isToolRelated = false
        }

        if isToolRelated {
            playSound(named: agentToolSoundName[role])
        } else {
            playSound(named: agentMessageSoundName[role])
            speak(message.content, for: role)
        }
    }

    /// Immediately stops all active and queued speech across every agent synthesizer.
    func stopAll() {
        for synthesizer in synthesizers.values {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Plays the named system sound for preview purposes, bypassing all enable guards.
    func previewSound(named name: String) {
        playSound(named: name)
    }

    // MARK: - Settings mutators

    func setGloballyEnabled(_ enabled: Bool) {
        isGloballyEnabled = enabled
        if !enabled { stopAll() }
        UserDefaults.standard.set(enabled, forKey: "speech.globalEnabled")
    }

    func setEnabled(_ enabled: Bool, for role: AgentRole) {
        agentEnabled[role] = enabled
        if !enabled { synthesizers[role]?.stopSpeaking(at: .immediate) }
        UserDefaults.standard.set(enabled, forKey: "speech.\(role.rawValue).enabled")
    }

    func setVoice(_ identifier: String, for role: AgentRole) {
        agentVoiceIdentifier[role] = identifier
        UserDefaults.standard.set(identifier, forKey: "speech.\(role.rawValue).voice")
    }

    func setMessageSound(_ name: String, for role: AgentRole) {
        agentMessageSoundName[role] = name
        UserDefaults.standard.set(name, forKey: "speech.\(role.rawValue).messageSound")
    }

    func setToolSound(_ name: String, for role: AgentRole) {
        agentToolSoundName[role] = name
        UserDefaults.standard.set(name, forKey: "speech.\(role.rawValue).toolSound")
    }

    // MARK: - Private helpers

    private func speak(_ text: String, for role: AgentRole) {
        guard let synthesizer = synthesizers[role] else { return }
        let utterance = AVSpeechUtterance(string: text)
        let voiceID = agentVoiceIdentifier[role] ?? ""
        if !voiceID.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
        }
        synthesizer.speak(utterance)
    }

    private func playSound(named name: String?) {
        guard let name, !name.isEmpty else { return }
        // NSSound(named:) caches system sounds; fall back to file URL if not found
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            NSSound(contentsOf: url, byReference: false)?.play()
        }
    }

    private func loadSettings() {
        isGloballyEnabled = UserDefaults.standard.bool(forKey: "speech.globalEnabled")
        for role in AgentRole.allCases {
            let key = role.rawValue
            agentEnabled[role] = UserDefaults.standard.object(forKey: "speech.\(key).enabled") as? Bool ?? false
            agentVoiceIdentifier[role] = UserDefaults.standard.string(forKey: "speech.\(key).voice") ?? ""
            agentMessageSoundName[role] = UserDefaults.standard.string(forKey: "speech.\(key).messageSound") ?? ""
            agentToolSoundName[role] = UserDefaults.standard.string(forKey: "speech.\(key).toolSound") ?? ""
        }
    }
}
