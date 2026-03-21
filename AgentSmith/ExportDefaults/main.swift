import Foundation
import AgentSmithKit

/// CLI tool that reads the user's current AgentSmith settings from
/// UserDefaults and persisted config files, then outputs a `defaults.json`
/// to stdout (or a file path passed as the first argument).
///
/// Usage:
///   ExportDefaults                              # prints to stdout
///   ExportDefaults path/to/defaults.json        # writes to file

// MARK: - Read persisted LLM configs

guard let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
    fputs("Error: Could not locate Application Support directory\n", stderr)
    exit(1)
}
let appSupportDir = appSupportBase.appendingPathComponent("AgentSmith", isDirectory: true)
let llmConfigsURL = appSupportDir.appendingPathComponent("llm_configs.json")

var smithLLM = LLMConfiguration.smithDefault
var brownLLM = LLMConfiguration.brownDefault
var jonesLLM = LLMConfiguration.jonesDefault

if FileManager.default.fileExists(atPath: llmConfigsURL.path) {
    do {
        let data = try Data(contentsOf: llmConfigsURL)
        let configs = try JSONDecoder().decode([AgentRole: LLMConfiguration].self, from: data)
        if let s = configs[.smith] { smithLLM = s }
        if let b = configs[.brown] { brownLLM = b }
        if let j = configs[.jones] { jonesLLM = j }
    } catch {
        fputs("Warning: Failed to read LLM configs from \(llmConfigsURL.path): \(error)\n", stderr)
    }
}

// MARK: - Read UserDefaults for speech settings

// Attempt to load the app's UserDefaults by bundle identifier.
// If the bundle identifier doesn't match, this will return an empty defaults suite.
let ud = UserDefaults(suiteName: "com.nuclearcyborg.AgentSmith") ?? .standard

func readBool(_ key: String, default defaultValue: Bool) -> Bool {
    ud.object(forKey: key) as? Bool ?? defaultValue
}

func readString(_ key: String) -> String {
    ud.string(forKey: key) ?? ""
}

// Speech settings
let globalEnabled = readBool("speech.globalEnabled", default: true)

// Sound category storage keys (must match AgentSoundCategory.storageKey)
let categoryKeys = ["toUser", "toAgent", "public", "tool", "error"]

var agentSpeechDefaults: [AgentRole: AgentSpeechDefaults] = [:]
for role in AgentRole.allCases {
    let key = role.rawValue
    let enabled = readBool("speech.\(key).enabled", default: false)
    let voice = readString("speech.\(key).voice")

    var categories: [String: SoundConfigDefaults] = [:]
    for catKey in categoryKeys {
        let soundName = readString("speech.\(key).\(catKey).sound")
        let speakEnabled = readBool("speech.\(key).\(catKey).speak", default: false)
        categories[catKey] = SoundConfigDefaults(soundName: soundName, speakEnabled: speakEnabled)
    }

    agentSpeechDefaults[role] = AgentSpeechDefaults(
        enabled: enabled,
        voiceIdentifier: voice,
        categories: categories
    )
}

let speech = SpeechDefaults(
    globalEnabled: globalEnabled,
    agents: agentSpeechDefaults,
    user: UserSpeechDefaults(
        soundName: readString("speech.user.sound"),
        speakEnabled: readBool("speech.user.speak", default: false),
        voiceIdentifier: readString("speech.user.voice")
    ),
    narrator: NarratorDefaults(
        enabled: readBool("speech.narrator.enabled", default: false),
        voiceIdentifier: readString("speech.narrator.voice")
    ),
    security: SecuritySoundDefaults(
        safeSoundName: readString("speech.security.safe"),
        warnSoundName: readString("speech.security.warn"),
        denySoundName: readString("speech.security.deny")
    )
)

// MARK: - Read tuning defaults

// Try loading tuning values from the bundled defaults.json so this tool stays
// in sync with the app's shipped configuration without duplicating constants.
let bundledTuning: [AgentRole: AgentTuningDefaults]? = {
    // When run from the build products directory, look for defaults.json in the
    // main app bundle's Resources, or fall back to the source tree location.
    let candidates: [URL] = [
        Bundle.main.url(forResource: "defaults", withExtension: "json"),
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("../AgentSmith.app/Contents/Resources/defaults.json")
    ].compactMap { $0 }

    for url in candidates {
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        do {
            let data = try Data(contentsOf: url)
            let defaults = try JSONDecoder().decode(AppDefaults.self, from: data)
            return defaults.agentTuning
        } catch {
            fputs("Warning: Failed to read bundled defaults from \(url.path): \(error)\n", stderr)
        }
    }
    return nil
}()

let fallbackTuning: [AgentRole: AgentTuningDefaults] = [
    .smith: AgentTuningDefaults(pollInterval: 20, maxToolCalls: 100, messageDebounceInterval: 1),
    .brown: AgentTuningDefaults(pollInterval: 25, maxToolCalls: 100, messageDebounceInterval: 1),
    .jones: AgentTuningDefaults(pollInterval: 13, maxToolCalls: 100, messageDebounceInterval: 1)
]

let agentTuning = bundledTuning ?? fallbackTuning

// MARK: - Build and encode

let appDefaults = AppDefaults(
    llmConfigs: [.smith: smithLLM, .brown: brownLLM, .jones: jonesLLM],
    agentTuning: agentTuning,
    speech: speech
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

let jsonData: Data
do {
    jsonData = try encoder.encode(appDefaults)
} catch {
    fputs("Error: Failed to encode defaults: \(error)\n", stderr)
    exit(1)
}

// MARK: - Output

if CommandLine.arguments.count > 1 {
    let outputPath = CommandLine.arguments[1]
    let outputURL = URL(fileURLWithPath: outputPath)
    do {
        try jsonData.write(to: outputURL, options: .atomic)
        fputs("Wrote defaults to \(outputURL.path)\n", stderr)
    } catch {
        fputs("Error: Failed to write to \(outputPath): \(error)\n", stderr)
        exit(1)
    }
} else {
    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
        fputs("Error: Failed to convert JSON data to string\n", stderr)
        exit(1)
    }
    print(jsonString)
}
