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
    @State private var memorySimilarities: [UUID: Float] = [:]
    @State private var taskSummarySimilarities: [UUID: Float] = [:]
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false

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
        .onChange(of: searchText) {
            searchTask?.cancel()
            let query = searchText.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                memorySimilarities.removeAll()
                taskSummarySimilarities.removeAll()
                isSearching = false
                return
            }
            isSearching = true
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                let memResults = await viewModel.searchMemories(query: query)
                let taskResults = await viewModel.searchTaskSummaries(query: query)
                guard !Task.isCancelled else { return }

                var memScores: [UUID: Float] = [:]
                for r in memResults { memScores[r.memory.id] = r.similarity }
                memorySimilarities = memScores

                var taskScores: [UUID: Float] = [:]
                for r in taskResults { taskScores[r.summary.id] = r.similarity }
                taskSummarySimilarities = taskScores
                isSearching = false
            }
        }
        .onDisappear {
            searchTask?.cancel()
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
            .fixedSize()

            Picker("Source", selection: $filterSource) {
                Text("All Sources").tag(Optional<MemoryEntry.Source>.none)
                Text("User").tag(Optional<MemoryEntry.Source>.some(.user))
                Text("Smith").tag(Optional<MemoryEntry.Source>.some(.smith))
                Text("Brown").tag(Optional<MemoryEntry.Source>.some(.brown))
            }
            .frame(width: 160)
            .opacity(showTaskSummaries ? 0 : 1)
            .disabled(showTaskSummaries)

            Spacer()

            TextField("Semantic search…", text: $searchText)
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
            if isSearching { return [] }
            let scored = result.filter { memorySimilarities[$0.id] != nil }
            return scored.sorted { (memorySimilarities[$0.id] ?? 0) > (memorySimilarities[$1.id] ?? 0) }
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

                if let score = memorySimilarities[memory.id] {
                    Text(String(format: "%.0f%%", score * 100))
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(similarityColor(score))
                }

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
        if !searchText.isEmpty {
            if isSearching { return [] }
            let scored = viewModel.storedTaskSummaries.filter { taskSummarySimilarities[$0.id] != nil }
            return scored.sorted { (taskSummarySimilarities[$0.id] ?? 0) > (taskSummarySimilarities[$1.id] ?? 0) }
        }
        return viewModel.storedTaskSummaries
    }

    private var taskSummaryList: some View {
        List {
            ForEach(filteredTaskSummaries) { summary in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(summary.title)
                            .font(.body.bold())
                        Spacer()
                        if let score = taskSummarySimilarities[summary.id] {
                            Text(String(format: "%.0f%%", score * 100))
                                .font(.caption.bold().monospaced())
                                .foregroundStyle(similarityColor(score))
                        }
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

    private func similarityColor(_ score: Float) -> Color {
        if score >= 0.55 { return .green }
        if score >= 0.45 { return .yellow }
        if score >= 0.35 { return .orange }
        return .red
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
