import SwiftUI
import AgentSmithKit

/// Standalone window for browsing, editing, and deleting stored memories and task summaries.
struct MemoryEditorView: View {
    @Bindable var viewModel: AppViewModel

    @State private var searchText = ""
    @State private var filterSource: MemoryEntry.Source?
    @State private var editingMemoryID: UUID?
    @State private var editContent = ""
    @State private var editTags = ""
    @State private var showTaskSummaries = false
    @State private var editError: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if showTaskSummaries {
                taskSummaryList
            } else {
                memoryList
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await viewModel.refreshMemories()
        }
        .alert("Error", isPresented: Binding(
            get: { editError != nil },
            set: { if !$0 { editError = nil } }
        )) {
            Button("OK") { editError = nil }
        } message: {
            Text(editError ?? "")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $showTaskSummaries) {
                Text("Memories (\(viewModel.storedMemories.count))").tag(false)
                Text("Task Summaries (\(viewModel.storedTaskSummaries.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 350)

            if !showTaskSummaries {
                Picker("Source", selection: $filterSource) {
                    Text("All Sources").tag(Optional<MemoryEntry.Source>.none)
                    Text("User").tag(Optional<MemoryEntry.Source>.some(.user))
                    Text("Smith").tag(Optional<MemoryEntry.Source>.some(.smith))
                    Text("Brown").tag(Optional<MemoryEntry.Source>.some(.brown))
                }
                .frame(maxWidth: 140)
            }

            Spacer()

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 250)
        }
        .padding(12)
    }

    // MARK: - Memory List

    private var filteredMemories: [MemoryEntry] {
        var result = viewModel.storedMemories
        if let source = filterSource {
            result = result.filter { $0.source == source }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.content.lowercased().contains(query) ||
                $0.tags.contains(where: { $0.lowercased().contains(query) })
            }
        }
        return result
    }

    private var memoryList: some View {
        List {
            ForEach(filteredMemories) { memory in
                if editingMemoryID == memory.id {
                    editRow(memory: memory)
                } else {
                    memoryRow(memory: memory)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func memoryRow(memory: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(memory.content)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Spacer()

                sourceBadge(memory.source)
            }

            HStack(spacing: 8) {
                if !memory.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(memory.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }

                Spacer()

                Text("Created \(memory.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if memory.lastAccessedAt != memory.createdAt {
                    Text("Accessed \(memory.lastAccessedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                Button("Edit") {
                    editingMemoryID = memory.id
                    editContent = memory.content
                    editTags = memory.tags.joined(separator: ", ")
                }
                .controlSize(.small)

                Button("Delete") {
                    Task { await viewModel.deleteMemory(id: memory.id) }
                }
                .controlSize(.small)
                .foregroundStyle(.red)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func editRow(memory: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Editing Memory")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $editContent)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .border(Color.secondary.opacity(0.2))

            LabeledContent("Tags") {
                TextField("comma-separated tags", text: $editTags)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    editingMemoryID = nil
                }
                .controlSize(.small)

                Button("Save") {
                    let newTags = editTags
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    Task {
                        do {
                            try await viewModel.updateMemory(
                                id: memory.id,
                                content: editContent,
                                tags: newTags
                            )
                            editingMemoryID = nil
                        } catch {
                            editError = "Failed to update memory: \(error.localizedDescription)"
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(editContent.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 4)
        .padding(8)
        .background(Color.accentColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Task Summary List

    private var filteredTaskSummaries: [TaskSummaryEntry] {
        guard !searchText.isEmpty else { return viewModel.storedTaskSummaries }
        let query = searchText.lowercased()
        return viewModel.storedTaskSummaries.filter {
            $0.title.lowercased().contains(query) ||
            $0.summary.lowercased().contains(query)
        }
    }

    private var taskSummaryList: some View {
        List {
            ForEach(filteredTaskSummaries) { summary in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(summary.title)
                            .font(.body.bold())
                        Spacer()
                        Text(summary.status.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(statusColor(summary.status).opacity(0.15))
                            .foregroundStyle(statusColor(summary.status))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    Text(summary.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Text("Created \(summary.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Helpers

    private func sourceBadge(_ source: MemoryEntry.Source) -> some View {
        Text(source.rawValue.capitalized)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(sourceColor(source).opacity(0.15))
            .foregroundStyle(sourceColor(source))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func sourceColor(_ source: MemoryEntry.Source) -> Color {
        switch source {
        case .user: return .blue
        case .smith: return .green
        case .brown: return .orange
        }
    }

    private func statusColor(_ status: AgentTask.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .running: return .blue
        case .awaitingReview: return .orange
        case .completed: return .green
        case .failed: return .red
        case .paused: return .secondary
        }
    }
}
