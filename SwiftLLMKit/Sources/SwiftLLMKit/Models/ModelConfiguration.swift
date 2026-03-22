import Foundation

/// A user-defined configuration pairing a provider + model with inference settings.
public struct ModelConfiguration: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for this configuration.
    public let id: UUID
    /// User-defined name, e.g. "Claude Heavy", "Local Fast".
    public var name: String
    /// References `ModelProvider.id`.
    public var providerID: String
    /// Raw model ID from the provider (used in API calls).
    public var modelID: String
    /// Sampling temperature.
    public var temperature: Double
    /// Maximum tokens to generate per response.
    public var maxOutputTokens: Int
    /// Total context window budget in tokens (for conversation pruning).
    public var maxContextTokens: Int
    /// Anthropic extended thinking token budget. Only relevant for `.anthropic` providers.
    public var thinkingBudget: Int?
    /// Whether to request streaming responses.
    public var streaming: Bool
    /// Set during validation — `false` if the config references a missing provider/model.
    public var isValid: Bool
    /// Human-readable reason the configuration is invalid, if any.
    public var validationError: String?

    public init(
        id: UUID = UUID(),
        name: String,
        providerID: String,
        modelID: String,
        temperature: Double = 0.7,
        maxOutputTokens: Int = 4096,
        maxContextTokens: Int = 128_000,
        thinkingBudget: Int? = nil,
        streaming: Bool = true,
        isValid: Bool = false,
        validationError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.modelID = modelID
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.maxContextTokens = maxContextTokens
        self.thinkingBudget = thinkingBudget
        self.streaming = streaming
        self.isValid = isValid
        self.validationError = validationError
    }
}
