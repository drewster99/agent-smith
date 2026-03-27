import Foundation
import SwiftLLMKit

/// Configuration for connecting to an LLM endpoint.
public struct LLMConfiguration: Codable, Sendable, Equatable {
    public var endpoint: URL
    public var apiKey: String
    public var model: String
    public var temperature: Double
    public var maxTokens: Int
    /// Total context window size in tokens. Used for conversation history pruning.
    public var contextWindowSize: Int
    /// Which API protocol this endpoint speaks.
    public var providerType: ProviderType
    /// Anthropic extended thinking token budget. Only relevant when `providerType` is `.anthropic`.
    /// When set and > 0, the provider includes a `thinking` block in the request body.
    public var thinkingBudget: Int?
    /// When true, full request/response JSON is logged to `$TMPDIR/AgentSmith-LLM-Logs/`.
    /// Not persisted — set programmatically at runtime.
    public var verboseLogging: Bool = false

    private enum CodingKeys: String, CodingKey {
        case endpoint, apiKey, model, temperature, maxTokens, contextWindowSize, providerType, thinkingBudget
    }

    public init(
        endpoint: URL,
        apiKey: String = "",
        model: String,
        temperature: Double = 0.7,
        maxTokens: Int = 4096,
        contextWindowSize: Int = 128_000,
        providerType: ProviderType = .openAICompatible,
        thinkingBudget: Int? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextWindowSize = contextWindowSize
        self.providerType = providerType
        self.thinkingBudget = thinkingBudget
    }

    /// Backward-compatible decoder: old JSON without `providerType` defaults to `.openAICompatible`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(URL.self, forKey: .endpoint)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        model = try container.decode(String.self, forKey: .model)
        temperature = try container.decode(Double.self, forKey: .temperature)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        contextWindowSize = try container.decode(Int.self, forKey: .contextWindowSize)
        providerType = try container.decodeIfPresent(ProviderType.self, forKey: .providerType) ?? .openAICompatible
        thinkingBudget = try container.decodeIfPresent(Int.self, forKey: .thinkingBudget)
    }

    // MARK: - Defaults

    /// Default endpoint for local Ollama (native API).
    public static let defaultOllamaEndpoint: URL = {
        guard let url = URL(string: "http://localhost:11434/api") else {
            preconditionFailure("Invalid default endpoint URL literal")
        }
        return url
    }()

    /// Default endpoint for Ollama cloud API.
    public static let defaultOllamaCloudEndpoint: URL = {
        guard let url = URL(string: "https://ollama.com/api") else {
            preconditionFailure("Invalid default endpoint URL literal")
        }
        return url
    }()

    /// Default configuration targeting a local Ollama instance using the native API.
    public static let ollamaDefault = LLMConfiguration(
        endpoint: defaultOllamaEndpoint,
        model: "llama3.1",
        providerType: .ollama
    )

    /// Default Smith (Orchestrator) configuration.
    public static let smithDefault = LLMConfiguration(
        endpoint: defaultOllamaCloudEndpoint,
        model: "nemotron-3-nano:30b",
        temperature: 0.1,
        maxTokens: 32_768,
        providerType: .ollama
    )

    /// Default Brown (Executor) configuration.
    public static let brownDefault = LLMConfiguration(
        endpoint: defaultOllamaCloudEndpoint,
        model: "deepseek-v3.2",
        temperature: 0.3,
        maxTokens: 32_768,
        providerType: .ollama
    )

    /// Default Jones (Safety Monitor) configuration.
    public static let jonesDefault = LLMConfiguration(
        endpoint: defaultOllamaCloudEndpoint,
        model: "gpt-oss:20b",
        temperature: 0.1,
        maxTokens: 32_768,
        providerType: .ollama
    )

}
