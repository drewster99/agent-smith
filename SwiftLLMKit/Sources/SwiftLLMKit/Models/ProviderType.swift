import Foundation

/// Selects which LLM API protocol a provider endpoint speaks.
public enum ProviderType: String, Codable, Sendable, CaseIterable, Equatable {
    case anthropic
    case openAICompatible
    case ollama
    case mistral
    case gemini
    case huggingFace
    case lmStudio
    case xAI

    /// The prefix LiteLLM uses for this provider's models (e.g. "mistral/" for `mistral/mistral-large-2512`).
    /// Returns `nil` for local-only providers that have no LiteLLM pricing data.
    public var liteLLMPrefix: String? {
        switch self {
        case .anthropic: return "anthropic"
        case .openAICompatible: return "openai"
        case .ollama: return "ollama"
        case .mistral: return "mistral"
        case .gemini: return "gemini"
        case .huggingFace: return nil
        case .lmStudio: return nil
        case .xAI: return "xai"
        }
    }

    /// Human-readable name for display.
    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAICompatible: return "OpenAI Compatible"
        case .ollama: return "Ollama"
        case .mistral: return "Mistral"
        case .gemini: return "Google Gemini"
        case .huggingFace: return "Hugging Face"
        case .lmStudio: return "LM Studio"
        case .xAI: return "xAI (Grok)"
        }
    }
}
