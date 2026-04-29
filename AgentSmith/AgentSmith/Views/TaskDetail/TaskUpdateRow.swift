import SwiftUI
import AgentSmithKit

/// Single timestamped update entry in the Task Detail window's "Updates" list. One view
/// per ForEach iteration — keeps the loop body free of nested layout primitives.
struct TaskUpdateRow: View {
    let update: AgentTask.TaskUpdate

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(update.date.formatted(date: .omitted, time: .standard))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            MarkdownText(content: update.message, baseFont: .callout)
        }
    }
}
