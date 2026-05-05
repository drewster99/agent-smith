import SwiftUI
import AgentSmithKit

/// Single relevant-memory entry rendered in the Task Detail window's "Memories" section.
///
/// Layout: a fixed-width `%match` column on the leading edge and a markdown body on the
/// trailing edge. The body is prefixed with the memory's most recent date in parentheses
/// (`lastUpdatedAt` if present, otherwise `createdAt`). Defaults to a 2-line preview;
/// tapping the row toggles full expansion.
struct TaskRelevantMemoryRow: View {
    let memory: RelevantMemory
    /// Externally-driven expanded state. The parent (`Related context` section) toggles
    /// every row at once when the section is expanded; individual rows can also be
    /// tapped to expand/collapse independently.
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.0f%%", memory.similarity * 100))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .leading)
                MarkdownText(content: prefixedContent, baseFont: .callout)
                    .textSelection(.enabled)
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `(May 5, 2026 at 11:27:33 AM) <memory body>` — falls back to `createdAt` when
    /// `lastUpdatedAt` is nil. When neither is set (legacy tasks saved before the date
    /// fields existed), the parenthetical is omitted.
    private var prefixedContent: String {
        guard let date = memory.lastUpdatedAt ?? memory.createdAt else {
            return memory.content
        }
        return "(\(Self.format(date))) \(memory.content)"
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
