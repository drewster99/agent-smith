import Foundation

/// A configured LLM provider — connection details for a specific API endpoint.
/// API keys are stored separately in Keychain, not in this struct.
public struct ModelProvider: Codable, Identifiable, Sendable, Equatable {
    /// Stable identifier, e.g. "anthropic-1", "ollama-local".
    public let id: String
    /// User-facing name, e.g. "Anthropic", "My Ollama Server".
    public var name: String
    /// Which API protocol this endpoint speaks.
    public var apiType: ProviderType
    /// Base URL for the provider's API.
    public var endpoint: URL

    public init(id: String, name: String, apiType: ProviderType, endpoint: URL) {
        self.id = id
        self.name = name
        self.apiType = apiType
        self.endpoint = endpoint
    }
}
