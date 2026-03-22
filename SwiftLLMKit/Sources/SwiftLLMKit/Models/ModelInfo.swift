import Foundation

/// Metadata about a specific model available from a provider.
public struct ModelInfo: Codable, Identifiable, Sendable, Equatable {
    /// Composite identifier: `providerID/modelID`.
    public var id: String { "\(providerID)/\(modelID)" }

    /// The provider this model belongs to.
    public let providerID: String
    /// The raw model identifier as used in API calls.
    public let modelID: String
    /// Human-readable name (e.g. "Claude Opus 4.6").
    public var displayName: String
    /// When the model was created or last modified.
    public var createdAt: Date?
    /// Maximum input context window in tokens.
    public var maxInputTokens: Int?
    /// Maximum output tokens the model can generate.
    public var maxOutputTokens: Int?
    /// Feature capabilities of this model.
    public var capabilities: ModelCapabilities
    /// Compact size label, e.g. "8.6B" (Ollama).
    public var sizeLabel: String?
    /// Quantization level, e.g. "Q4_K_M" (Ollama).
    public var quantizationLabel: String?
    /// Input cost in USD per million tokens.
    public var inputCostPerMillionTokens: Double?
    /// Output cost in USD per million tokens.
    public var outputCostPerMillionTokens: Double?

    public init(
        providerID: String,
        modelID: String,
        displayName: String = "",
        createdAt: Date? = nil,
        maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        capabilities: ModelCapabilities = ModelCapabilities(),
        sizeLabel: String? = nil,
        quantizationLabel: String? = nil,
        inputCostPerMillionTokens: Double? = nil,
        outputCostPerMillionTokens: Double? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName.isEmpty ? modelID : displayName
        self.createdAt = createdAt
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.sizeLabel = sizeLabel
        self.quantizationLabel = quantizationLabel
        self.inputCostPerMillionTokens = inputCostPerMillionTokens
        self.outputCostPerMillionTokens = outputCostPerMillionTokens
    }

    /// Whether the model was created/modified within the last 90 days.
    public var isNew: Bool {
        guard let createdAt else { return false }
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date.distantPast
        return createdAt > cutoff
    }
}
