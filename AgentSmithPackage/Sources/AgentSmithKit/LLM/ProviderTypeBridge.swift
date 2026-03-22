import SwiftLLMKit

extension SwiftLLMKit.ProviderType {
    /// Converts to the AgentSmithKit `ProviderType` used by `LLMConfiguration`.
    public var toLegacy: AgentSmithKit.ProviderType {
        switch self {
        case .anthropic: return .anthropic
        case .openAICompatible: return .openAICompatible
        case .ollama: return .ollama
        }
    }
}

extension AgentSmithKit.ProviderType {
    /// Converts to the SwiftLLMKit `ProviderType`.
    public var toKit: SwiftLLMKit.ProviderType {
        switch self {
        case .anthropic: return .anthropic
        case .openAICompatible: return .openAICompatible
        case .ollama: return .ollama
        }
    }
}
