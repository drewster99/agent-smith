import SwiftUI
import AgentSmithKit

/// Standalone window showing full task detail: metadata, description, commentary, and results.
struct TaskDetailWindow: View {
    let task: AgentTask
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: Header
                HStack(alignment: .top) {
                    Image(systemName: TaskStatusBadge.icon(for: task.status))
                        .font(.title2)
                        .foregroundStyle(TaskStatusBadge.color(for: task.status))
                    Text(task.title)
                        .font(.title.bold())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }

                // MARK: Metadata
                metadataSection

                Divider()

                // MARK: Description
                sectionHeader("Description")
                Text(task.description)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // MARK: Commentary
                if let commentary = task.commentary, !commentary.isEmpty {
                    Divider()
                    sectionHeader("Commentary")
                    MarkdownText(content: commentary, baseFont: .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // MARK: Updates
                if !task.updates.isEmpty {
                    Divider()
                    sectionHeader("Updates")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(task.updates.enumerated()), id: \.offset) { _, update in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(update.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                Text(update.message)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // MARK: Result
                if let result = task.result, !result.isEmpty {
                    Divider()
                    sectionHeader("Result")
                    MarkdownText(content: result, baseFont: .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // MARK: Footer
                Text("ID: \(task.id.uuidString)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(task.title)
    }

    // MARK: - Metadata grid

    private var metadataSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                metadataLabel("Status")
                Text(task.status.rawValue.capitalized)
                    .foregroundStyle(TaskStatusBadge.color(for: task.status))
                    .fontWeight(.medium)
            }

            GridRow {
                metadataLabel("Created")
                Text(task.createdAt.formatted(date: .abbreviated, time: .standard))
            }

            if let startedAt = task.startedAt {
                GridRow {
                    metadataLabel("Started")
                    Text(startedAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            if let completedAt = task.completedAt {
                GridRow {
                    metadataLabel(task.status == .failed ? "Failed" : "Completed")
                    Text(completedAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            if let elapsed = elapsedTime {
                GridRow {
                    metadataLabel("Elapsed")
                    Text(elapsed)
                }
            }
        }
        .font(.callout)
    }

    private func metadataLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
    }

    // MARK: - Elapsed time

    /// Computes a human-readable elapsed duration from `startedAt` to `completedAt`.
    private var elapsedTime: String? {
        guard let start = task.startedAt else { return nil }
        let end = task.completedAt ?? Date()
        let interval = end.timeIntervalSince(start)
        guard interval >= 0 else { return nil }

        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}
