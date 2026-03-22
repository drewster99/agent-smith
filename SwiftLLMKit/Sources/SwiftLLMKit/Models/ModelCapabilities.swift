import Foundation

/// Feature flags describing what a model supports.
public struct ModelCapabilities: Codable, Sendable, Equatable {
    public var toolUse: Bool
    public var vision: Bool
    public var reasoning: Bool
    public var codeExecution: Bool
    public var promptCaching: Bool
    public var computerUse: Bool
    public var audioInput: Bool
    public var audioOutput: Bool
    public var videoInput: Bool
    public var responseSchema: Bool
    public var parallelToolCalls: Bool

    public init(
        toolUse: Bool = false,
        vision: Bool = false,
        reasoning: Bool = false,
        codeExecution: Bool = false,
        promptCaching: Bool = false,
        computerUse: Bool = false,
        audioInput: Bool = false,
        audioOutput: Bool = false,
        videoInput: Bool = false,
        responseSchema: Bool = false,
        parallelToolCalls: Bool = false
    ) {
        self.toolUse = toolUse
        self.vision = vision
        self.reasoning = reasoning
        self.codeExecution = codeExecution
        self.promptCaching = promptCaching
        self.computerUse = computerUse
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        self.videoInput = videoInput
        self.responseSchema = responseSchema
        self.parallelToolCalls = parallelToolCalls
    }

    /// Human-readable labels for capabilities that are enabled.
    public var enabledLabels: [String] {
        var labels: [String] = []
        if toolUse { labels.append("Tools") }
        if vision { labels.append("Vision") }
        if reasoning { labels.append("Reasoning") }
        if codeExecution { labels.append("Code Exec") }
        if promptCaching { labels.append("Caching") }
        if computerUse { labels.append("Computer Use") }
        if audioInput { labels.append("Audio In") }
        if audioOutput { labels.append("Audio Out") }
        if videoInput { labels.append("Video In") }
        if responseSchema { labels.append("Schema") }
        if parallelToolCalls { labels.append("Parallel Tools") }
        return labels
    }
}
