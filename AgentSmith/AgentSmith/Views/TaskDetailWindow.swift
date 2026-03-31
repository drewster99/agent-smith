import SwiftUI
import AgentSmithKit

/// Standalone window showing full task detail: metadata, description, commentary, and results.
struct TaskDetailWindow: View {
    let taskID: UUID
    var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    /// Live task looked up from the view model on each render, so updates are reflected.
    private var task: AgentTask? {
        viewModel.tasks.first { $0.id == taskID }
    }

    var body: some View {
        if let task {
            taskContent(task)
        } else {
            ContentUnavailableView(
                "Task Not Found",
                systemImage: "questionmark.circle",
                description: Text("This task may have been deleted.")
            )
            .frame(minWidth: 600, minHeight: 400)
        }
    }

    private func taskContent(_ task: AgentTask) -> some View {
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
                metadataSection(for: task)

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

                // MARK: Summary
                if let summary = task.summary, !summary.isEmpty {
                    Divider()
                    sectionHeader("Summary")
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.purple.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // MARK: Relevant Context
                if Self.hasRelevantContext(task) {
                    Divider()
                    sectionHeader("Context Retrieved at Creation")

                    if let memories = task.relevantMemories, !memories.isEmpty {
                        Text("Memories")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(memories.enumerated()), id: \.offset) { _, memory in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(String(format: "%.0f%%", memory.similarity * 100))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                    Text(memory.content)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let priorTasks = task.relevantPriorTasks, !priorTasks.isEmpty {
                        Text("Prior Tasks")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(priorTasks.enumerated()), id: \.offset) { _, prior in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(prior.title)
                                            .font(.callout.bold())
                                        Text(String(format: "%.0f%%", prior.similarity * 100))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(prior.summary)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

    private func metadataSection(for task: AgentTask) -> some View {
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

            if let elapsed = Self.elapsedTime(for: task) {
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

    /// Whether the task has any relevant memories or prior task summaries attached.
    private static func hasRelevantContext(_ task: AgentTask) -> Bool {
        let hasMemories = task.relevantMemories.map { !$0.isEmpty } ?? false
        let hasPriorTasks = task.relevantPriorTasks.map { !$0.isEmpty } ?? false
        return hasMemories || hasPriorTasks
    }

    // MARK: - Elapsed time

    /// Computes a human-readable elapsed duration from `startedAt` to `completedAt`.
    private static func elapsedTime(for task: AgentTask) -> String? {
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
