import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Subtitle row beneath an `AgentCard` header showing the model name (with stats popover)
/// and either context-token usage or the model's max context label.
struct AgentCardModelInfoLine: View {
    let modelConfig: ModelConfiguration
    let llmTurns: [LLMTurnRecord]
    let role: AgentRole

    @State private var showingModelStats = false

    var body: some View {
        let contextLabel = Self.formatTokenCount(modelConfig.maxContextTokens)
        let lastInputTokens = llmTurns.last?.usage?.inputTokens
        let contextPercent: Int? = {
            guard modelConfig.maxContextTokens > 0, let inputTokens = lastInputTokens else { return nil }
            return min(100, (inputTokens * 100) / modelConfig.maxContextTokens)
        }()

        HStack(spacing: 6) {
            Button(action: { showingModelStats = true }, label: {
                Text(modelConfig.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
            })
            .buttonStyle(.plain)
            .popover(isPresented: $showingModelStats, arrowEdge: .bottom) {
                ModelStatsPopover(turns: llmTurns, modelID: modelConfig.modelID, role: role)
            }
            Spacer()
            if let pct = contextPercent, let tokens = lastInputTokens {
                Text("\(Self.formatTokenCount(tokens)) / \(contextLabel) (\(pct)%)")
            } else {
                Text("\(contextLabel) ctx")
            }
        }
        .font(AppFonts.inspectorLabel)
        .foregroundStyle(.tertiary)
    }

    /// Formats a token count as a compact label (e.g. 128000 → "128K", 1048576 → "1.0M").
    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            let formatted = String(format: "%.1f", value)
            let label = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
            return "\(label)M"
        } else if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }
}
