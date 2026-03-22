import Foundation
import os

private let logger = Logger(subsystem: "SwiftLLMKit", category: "ModelMetadata")

/// Manages the LiteLLM model metadata cache.
///
/// Downloads the LiteLLM model cost map from GitHub, caches it locally,
/// and provides lookup by model ID. Uses conditional HTTP requests
/// (ETag/Last-Modified) to avoid redundant downloads.
public actor ModelMetadataService {
    private let storageDirectory: URL
    private let userDefaults: UserDefaults
    private let userDefaultsSuiteName: String

    /// In-memory index: raw model ID → parsed metadata.
    private var metadataIndex: [String: LiteLLMEntry] = [:]
    /// Secondary index with provider prefixes stripped for fuzzy matching.
    private var strippedIndex: [String: LiteLLMEntry] = [:]

    private static let liteLLMURL: URL = {
        guard let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json") else {
            preconditionFailure("Invalid LiteLLM metadata URL literal")
        }
        return url
    }()
    private static let metadataFilename = "litellm_metadata.json"
    private static let headersFilename = "litellm_headers.json"
    private static let lastRefreshKey = "LastModelRefreshDate"

    public init(storageDirectory: URL, userDefaultsSuiteName: String) {
        self.storageDirectory = storageDirectory
        self.userDefaultsSuiteName = userDefaultsSuiteName
        guard let defaults = UserDefaults(suiteName: userDefaultsSuiteName) else {
            preconditionFailure("Failed to create UserDefaults suite: \(userDefaultsSuiteName)")
        }
        self.userDefaults = defaults
    }

    /// Whether a refresh is needed (different YYYYMMDD from last refresh).
    public func needsRefresh() -> Bool {
        let today = Self.todayString()
        let last = userDefaults.string(forKey: Self.lastRefreshKey) ?? ""
        return last != today
    }

    /// Refreshes the LiteLLM cache if the YYYYMMDD gate allows it.
    public func refreshIfNeeded() async {
        guard needsRefresh() else {
            // Load from disk if not in memory
            if metadataIndex.isEmpty {
                loadFromDisk()
            }
            return
        }
        await forceRefresh()
    }

    /// Always fetches fresh metadata, bypassing the date gate.
    public func forceRefresh() async {
        do {
            let changed = try await fetchIfChanged()
            if changed {
                logger.info("LiteLLM metadata updated")
            } else {
                logger.info("LiteLLM metadata unchanged (304)")
            }
        } catch {
            logger.error("LiteLLM fetch failed: \(error.localizedDescription, privacy: .public)")
            // Fall back to cached data
            if metadataIndex.isEmpty {
                loadFromDisk()
            }
        }
        userDefaults.set(Self.todayString(), forKey: Self.lastRefreshKey)
    }

    /// Looks up metadata for a model by its raw ID.
    /// Tries exact match first, then strips common provider prefixes.
    public func metadata(for modelID: String) -> LiteLLMEntry? {
        if let entry = metadataIndex[modelID] {
            return entry
        }
        // Try stripped index
        let stripped = Self.stripProviderPrefix(modelID)
        return strippedIndex[stripped]
    }

    // MARK: - Private

    private func fetchIfChanged() async throws -> Bool {
        let cachedHeaders = loadCachedHeaders()

        var request = URLRequest(url: Self.liteLLMURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        if let etag = cachedHeaders["ETag"] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = cachedHeaders["Last-Modified"] {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelMetadataError.invalidResponse
        }

        if http.statusCode == 304 {
            // Not modified — load from disk if needed
            if metadataIndex.isEmpty {
                loadFromDisk()
            }
            return false
        }

        guard (200..<300).contains(http.statusCode) else {
            throw ModelMetadataError.httpError(statusCode: http.statusCode)
        }

        // Save raw data and headers
        try ensureDirectory()
        let metadataURL = storageDirectory.appendingPathComponent(Self.metadataFilename)
        try data.write(to: metadataURL, options: .atomic)

        var headers: [String: String] = [:]
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            headers["ETag"] = etag
        }
        if let lastModified = http.value(forHTTPHeaderField: "Last-Modified") {
            headers["Last-Modified"] = lastModified
        }
        let headersURL = storageDirectory.appendingPathComponent(Self.headersFilename)
        let headersData = try JSONEncoder().encode(headers)
        try headersData.write(to: headersURL, options: .atomic)

        // Parse into memory
        parseMetadata(data)
        return true
    }

    private func loadFromDisk() {
        let metadataURL = storageDirectory.appendingPathComponent(Self.metadataFilename)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return }
        do {
            let data = try Data(contentsOf: metadataURL)
            parseMetadata(data)
            logger.debug("Loaded LiteLLM metadata from disk (\(self.metadataIndex.count) entries)")
        } catch {
            logger.error("Failed to load cached LiteLLM metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func parseMetadata(_ data: Data) {
        do {
            guard let rawDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("LiteLLM metadata is not a JSON dictionary")
                return
            }

            var index: [String: LiteLLMEntry] = [:]
            var stripped: [String: LiteLLMEntry] = [:]

            for (key, value) in rawDict {
                // Skip the "sample_spec" key and any non-dict entries
                guard let modelDict = value as? [String: Any] else { continue }

                let entry = LiteLLMEntry(
                    maxInputTokens: modelDict["max_input_tokens"] as? Int,
                    maxOutputTokens: modelDict["max_output_tokens"] as? Int,
                    inputCostPerToken: modelDict["input_cost_per_token"] as? Double,
                    outputCostPerToken: modelDict["output_cost_per_token"] as? Double,
                    supportsToolUse: modelDict["supports_function_calling"] as? Bool ?? false,
                    supportsVision: modelDict["supports_vision"] as? Bool ?? false,
                    supportsReasoning: modelDict["supports_reasoning"] as? Bool ?? false,
                    supportsPromptCaching: modelDict["supports_prompt_caching"] as? Bool ?? false,
                    supportsComputerUse: modelDict["supports_computer_use"] as? Bool ?? false,
                    supportsAudioInput: modelDict["supports_audio_input"] as? Bool ?? false,
                    supportsAudioOutput: modelDict["supports_audio_output"] as? Bool ?? false,
                    supportsVideoInput: modelDict["supports_video_input"] as? Bool ?? false,
                    supportsResponseSchema: modelDict["supports_response_schema"] as? Bool ?? false,
                    supportsParallelToolCalls: modelDict["supports_parallel_tool_calls"] as? Bool ?? false,
                    mode: modelDict["mode"] as? String
                )

                index[key] = entry
                let strippedKey = Self.stripProviderPrefix(key)
                // Only set in stripped index if different from the full key
                if strippedKey != key {
                    stripped[strippedKey] = entry
                }
            }

            metadataIndex = index
            strippedIndex = stripped
        } catch {
            logger.error("Failed to parse LiteLLM JSON: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadCachedHeaders() -> [String: String] {
        let headersURL = storageDirectory.appendingPathComponent(Self.headersFilename)
        guard FileManager.default.fileExists(atPath: headersURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: headersURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            return [:]
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    /// Strips common provider prefixes like "anthropic/", "openai/", "ollama/" from model IDs.
    static func stripProviderPrefix(_ modelID: String) -> String {
        let prefixes = [
            "anthropic/", "openai/", "ollama/", "azure/", "bedrock/",
            "vertex_ai/", "cohere/", "mistral/", "groq/", "deepseek/",
            "together_ai/", "fireworks_ai/", "perplexity/", "anyscale/"
        ]
        for prefix in prefixes {
            if modelID.hasPrefix(prefix) {
                return String(modelID.dropFirst(prefix.count))
            }
        }
        return modelID
    }
}

/// A parsed entry from the LiteLLM model cost/metadata map.
public struct LiteLLMEntry: Sendable {
    public let maxInputTokens: Int?
    public let maxOutputTokens: Int?
    /// Cost per single token for input, in USD.
    public let inputCostPerToken: Double?
    /// Cost per single token for output, in USD.
    public let outputCostPerToken: Double?
    public let supportsToolUse: Bool
    public let supportsVision: Bool
    public let supportsReasoning: Bool
    public let supportsPromptCaching: Bool
    public let supportsComputerUse: Bool
    public let supportsAudioInput: Bool
    public let supportsAudioOutput: Bool
    public let supportsVideoInput: Bool
    public let supportsResponseSchema: Bool
    public let supportsParallelToolCalls: Bool
    public let mode: String?

    /// Merges this LiteLLM entry's capabilities into an existing `ModelCapabilities`,
    /// filling in only fields that are currently `false`.
    public func mergeCapabilities(into capabilities: inout ModelCapabilities) {
        if supportsToolUse { capabilities.toolUse = true }
        if supportsVision { capabilities.vision = true }
        if supportsReasoning { capabilities.reasoning = true }
        if supportsPromptCaching { capabilities.promptCaching = true }
        if supportsComputerUse { capabilities.computerUse = true }
        if supportsAudioInput { capabilities.audioInput = true }
        if supportsAudioOutput { capabilities.audioOutput = true }
        if supportsVideoInput { capabilities.videoInput = true }
        if supportsResponseSchema { capabilities.responseSchema = true }
        if supportsParallelToolCalls { capabilities.parallelToolCalls = true }
    }
}

/// Errors from the metadata service.
public enum ModelMetadataError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid HTTP response from LiteLLM metadata server"
        case .httpError(let code):
            return "LiteLLM metadata fetch failed with HTTP \(code)"
        }
    }
}
