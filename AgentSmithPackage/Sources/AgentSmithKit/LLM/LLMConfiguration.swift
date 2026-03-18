import Foundation

/// Selects which LLM API protocol to use for a given endpoint.
public enum ProviderType: String, Codable, Sendable, CaseIterable, Equatable {
    case anthropic
    case openAICompatible
    case ollama

    /// Human-readable name for display.
    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAICompatible: return "OpenAI Compatible"
        case .ollama: return "Ollama"
        }
    }
}

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

    private enum CodingKeys: String, CodingKey {
        case endpoint, apiKey, model, temperature, maxTokens, contextWindowSize, providerType
    }

    public init(
        endpoint: URL,
        apiKey: String = "",
        model: String,
        temperature: Double = 0.7,
        maxTokens: Int = 4096,
        contextWindowSize: Int = 128_000,
        providerType: ProviderType = .openAICompatible
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextWindowSize = contextWindowSize
        self.providerType = providerType
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
    }

    // MARK: - Defaults

    /// Default endpoint for local Ollama (native API).
    public static let defaultOllamaEndpoint: URL = {
        guard let url = URL(string: "http://localhost:11434/api") else {
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
}
