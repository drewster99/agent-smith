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
