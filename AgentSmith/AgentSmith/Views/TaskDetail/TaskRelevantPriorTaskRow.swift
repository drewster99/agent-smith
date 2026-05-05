import SwiftUI
import AgentSmithKit

/// Single prior-task summary entry rendered in the Task Detail window's "Prior Tasks"
/// section.
///
/// Layout matches `TaskRelevantMemoryRow`: a fixed-width `%match` column on the leading
/// edge, then a stacked title line + 2-line summary preview on the trailing edge. The
/// title is the only click target that opens the referenced task in a new detail window
/// — body taps toggle expand/collapse, links inside the markdown body remain clickable.
struct TaskRelevantPriorTaskRow: View {
    let priorTask: RelevantPriorTask
    /// Session this row belongs to — used to build the `TaskDetailTarget` for opening
    /// the referenced prior task in its own window.
    let sessionID: UUID
    /// Externally-driven expanded state shared with peer rows in the same section.
    @Binding var isExpanded: Bool

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.0f%%", priorTask.similarity * 100))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    titleLine()
                    MarkdownText(content: priorTask.summary, baseFont: .callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func titleLine() -> some View {
        HStack(spacing: 0) {
            if let date = priorTask.latestDate {
                Text("(\(Self.format(date))) ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                AgentSmithApp.showOrOpenTaskDetail(
                    target: TaskDetailTarget(sessionID: sessionID, taskID: priorTask.taskID),
                    openWindow: openWindow
                )
            } label: {
                Text(priorTask.title)
                    .font(.callout.bold())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Open this task in a new detail window")
            Spacer(minLength: 0)
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
