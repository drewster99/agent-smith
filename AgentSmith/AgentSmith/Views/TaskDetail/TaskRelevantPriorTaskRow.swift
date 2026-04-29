import SwiftUI
import AgentSmithKit

/// Single prior-task summary entry rendered in the Task Detail window's "Prior Tasks"
/// section.
struct TaskRelevantPriorTaskRow: View {
    let priorTask: RelevantPriorTask

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(priorTask.title)
                    .font(.callout.bold())
                Text(String(format: "%.0f%%", priorTask.similarity * 100))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            MarkdownText(content: priorTask.summary, baseFont: .callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
