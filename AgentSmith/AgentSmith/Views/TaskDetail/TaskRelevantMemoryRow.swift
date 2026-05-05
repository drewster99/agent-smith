import SwiftUI
import AgentSmithKit

/// Single relevant-memory entry rendered in the Task Detail window's "Memories" section.
///
/// Layout: a fixed-width `%match` column on the leading edge and a markdown body on the
/// trailing edge. The body is prefixed with the memory's most recent date in parentheses
/// (`lastUpdatedAt` if present, otherwise `createdAt`). In short mode only the first
/// paragraph of the memory is rendered, line-clamped to 2 lines; expanded mode shows the
/// full memory. The `(more)`/`(less)` link in the bottom-right toggles between the two.
struct TaskRelevantMemoryRow: View {
    let memory: RelevantMemory
    /// Externally-driven expanded state. The parent (`Related context` section) toggles
    /// every row at once when the section is expanded; individual rows can also be
    /// toggled independently via the disclosure link.
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%.0f%%", memory.similarity * 100))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                MarkdownText(content: prefixedContent, baseFont: .callout)
                    .textSelection(.enabled)
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasMoreContent {
                    HStack {
                        Spacer()
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Text(isExpanded ? "(less)" : "(more)")
                                .font(.caption)
                                .foregroundStyle(AppColors.disclosureToggle)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `(May 5, 2026 at 11:27:33 AM) <memory body>`. In short mode `<memory body>` is the
    /// first paragraph (text up to the first blank line) of `memory.content`. When neither
    /// `lastUpdatedAt` nor `createdAt` is set (legacy tasks saved before the date fields
    /// existed), the parenthetical is omitted.
    private var prefixedContent: String {
        let body = isExpanded ? memory.content : Self.firstParagraph(of: memory.content)
        guard let date = memory.lastUpdatedAt ?? memory.createdAt else {
            return body
        }
        return "(\(Self.format(date))) \(body)"
    }

    /// True when the short-mode preview hides content the user could expand to see —
    /// either the full memory has more paragraphs than the first or the first paragraph
    /// runs longer than the 2-line clamp can show.
    private var hasMoreContent: Bool {
        let first = Self.firstParagraph(of: memory.content)
        return first != memory.content || first.count > 80
    }

    /// Returns text up to the first blank-line separator, or the full text if there
    /// isn't one. Trailing whitespace from the boundary is stripped.
    private static func firstParagraph(of text: String) -> String {
        if let range = text.range(of: "\n\n") {
            return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
