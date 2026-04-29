import SwiftUI

/// Collapsible "Context: N memories, M prior tasks" section under `TaskCreatedBanner`.
/// Rendered only when the banner has at least one context entry attached.
struct TaskCreatedBannerContextSection: View {
    let memoryCount: Int
    let priorTaskCount: Int
    let contextMemories: String?
    let contextPriorTasks: String?
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3).padding(.horizontal, 10)

            Button(action: { isExpanded.toggle() }, label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(AppFonts.bannerIconSmall)
                        .foregroundStyle(.purple)

                    let parts = [
                        memoryCount > 0
                            ? "\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")"
                            : nil,
                        priorTaskCount > 0
                            ? "\(priorTaskCount) prior task\(priorTaskCount == 1 ? "" : "s")"
                            : nil
                    ].compactMap { $0 }

                    Text("Context: \(parts.joined(separator: ", "))")
                        .font(AppFonts.channelBody)
                        .foregroundStyle(.purple.opacity(0.8))

                    Text(isExpanded ? "(hide)" : "(show)")
                        .font(.caption)
                        .foregroundStyle(.blue)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let contextMemories {
                        Text("Memories")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        let memoryEntries = parseContextEntries(contextMemories)
                        ForEach(Array(memoryEntries.enumerated()), id: \.offset) { idx, entry in
                            ContextMemoryDividedRow(entry: entry, showsDivider: idx > 0)
                        }
                    }
                    if let contextPriorTasks {
                        Text("Prior Tasks")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        let taskEntries = parseContextEntries(contextPriorTasks)
                        ForEach(Array(taskEntries.enumerated()), id: \.offset) { idx, entry in
                            ContextEntryDividedRow(entry: entry, showsDivider: idx > 0)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
