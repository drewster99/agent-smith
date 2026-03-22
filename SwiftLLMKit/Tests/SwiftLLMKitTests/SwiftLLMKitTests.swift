import Testing
@testable import SwiftLLMKit

@Test func modelInfoCompositeID() {
    let info = ModelInfo(providerID: "anthropic-1", modelID: "claude-opus-4-6")
    #expect(info.id == "anthropic-1/claude-opus-4-6")
}
