import SwiftUI

/// Compact status indicator that sits at the right edge of `AgentCard`'s header. Picks
/// between four mutually-exclusive states (Thinking / Idle / Terminated / Not active)
/// based on the agent's current activity. Also renders the elapsed thinking timer when
/// the agent is processing.
struct AgentCardStatusBadge: View {
    let isProcessing: Bool
    let hasActivity: Bool
    let isJones: Bool
    /// True when the agent has activity history but no live tools — i.e. it has been
    /// terminated. Driven by `availableTools.isEmpty && !contextMessages.isEmpty`.
    let isTerminated: Bool
    let processingStartDate: Date?

    var body: some View {
        Group {
            if isProcessing {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(isJones ? "Evaluating" : "Thinking")
                        .font(AppFonts.inspectorLabel)
                        .foregroundStyle(.secondary)
                    if let start = processingStartDate {
                        ThinkingElapsedTime(since: start, font: AppFonts.inspectorLabel)
                    }
                }
            } else if hasActivity && isTerminated {
                Text("Terminated")
                    .font(AppFonts.inspectorLabel)
                    .foregroundStyle(.orange)
            } else if hasActivity {
                Text("Idle")
                    .font(AppFonts.inspectorLabel)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not active")
                    .font(AppFonts.inspectorLabel)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
