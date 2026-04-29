import SwiftUI
import AgentSmithKit

/// Single relevant-memory entry rendered in the Task Detail window's "Memories" section.
struct TaskRelevantMemoryRow: View {
    let memory: RelevantMemory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%.0f%%", memory.similarity * 100))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            MarkdownText(content: memory.content, baseFont: .callout)
                .textSelection(.enabled)
        }
    }
}
