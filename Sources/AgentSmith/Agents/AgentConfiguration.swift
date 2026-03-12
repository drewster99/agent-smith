import Foundation

/// Full configuration for a single agent instance.
public struct AgentConfiguration: Sendable {
    public var role: AgentRole
    public var llmConfig: LLMConfiguration
    public var systemPrompt: String
    public var toolNames: [String]

    public init(
        role: AgentRole,
        llmConfig: LLMConfiguration,
        systemPrompt: String? = nil,
        toolNames: [String] = []
    ) {
        self.role = role
        self.llmConfig = llmConfig
        self.systemPrompt = systemPrompt ?? role.baseSystemPrompt
        self.toolNames = toolNames
    }
}
