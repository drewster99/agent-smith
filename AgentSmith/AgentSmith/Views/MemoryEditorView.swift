import SwiftUI
import AgentSmithKit

/// Standalone window for browsing, editing, and deleting stored memories and task summaries.
/// Memories are shared across all sessions, so this view binds to `SharedAppState`.
struct MemoryEditorView: View {
    @Bindable var shared: SharedAppState

    @State private var searchText = ""
    @State private var filterSource: MemoryEntry.Source?
    @State private var editingMemoryID: UUID?
    @State private var editContent = ""
    @State private var editTags = ""
    @State private var showTaskSummaries = false
    @State private var editError: String?
    @State private var memorySimilarities: [UUID: Double] = [:]
    @State private var taskSummarySimilarities: [UUID: Double] = [:]
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    /// Set when the most recent search threw — surfaced as an inline empty-state.
    /// Cleared on a successful search or when the query is cleared.
    @State private var searchErrorMessage: String?
    /// Stats from the most recent successful search, displayed in the footer.
    @State private var searchStats: SearchStats?

    /// Per-search performance breakdown for the editor footer.
    private struct SearchStats: Equatable {
        let memoryDocCount: Int
        let memoryVectorCount: Int
        let taskDocCount: Int
        let taskVectorCount: Int
        let elapsedSeconds: Double

        var totalVectorCount: Int { memoryVectorCount + taskVectorCount }
        var totalDocCount: Int { memoryDocCount + taskDocCount }

        var elapsedMs: Double { elapsedSeconds * 1000 }

        var avgMsPerVector: Double {
            totalVectorCount == 0 ? 0 : elapsedMs / Double(totalVectorCount)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if showTaskSummaries {
                taskSummaryList
            } else {
                memoryList
            }
            statsFooter
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await shared.refreshMemories()
        }
        .onChange(of: searchText) {
            searchTask?.cancel()
            let query = searchText.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                memorySimilarities.removeAll()
                taskSummarySimilarities.removeAll()
                isSearching = false
                searchErrorMessage = nil
                searchStats = nil
                return
            }
            isSearching = true
            searchErrorMessage = nil
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                // Snapshot the corpus shape BEFORE the search so the stats reflect what
                // was actually searched (the corpus could change between snapshot and
                // display, e.g. if a memory is saved during the await).
                let memDocs = shared.storedMemories.count
                let memVectors = shared.storedMemories.reduce(0) { $0 + ($1.embedding.isEmpty ? 0 : 1) }
                let taskDocs = shared.storedTaskSummaries.count
                let taskVectors = shared.storedTaskSummaries.reduce(0) { $0 + ($1.embedding.isEmpty ? 0 : 1) }

                let started = Date()
                do {
                    let memResults = try await shared.searchMemories(query: query)
                    let taskResults = try await shared.searchTaskSummaries(query: query)
                    let elapsed = Date().timeIntervalSince(started)
                    guard !Task.isCancelled else { return }

                    var memScores: [UUID: Double] = [:]
                    for r in memResults { memScores[r.memory.id] = r.similarity }
                    memorySimilarities = memScores

                    var taskScores: [UUID: Double] = [:]
                    for r in taskResults { taskScores[r.summary.id] = r.similarity }
                    taskSummarySimilarities = taskScores
                    searchErrorMessage = nil
                    searchStats = SearchStats(
                        memoryDocCount: memDocs,
                        memoryVectorCount: memVectors,
                        taskDocCount: taskDocs,
                        taskVectorCount: taskVectors,
                        elapsedSeconds: elapsed
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    memorySimilarities.removeAll()
                    taskSummarySimilarities.removeAll()
                    searchErrorMessage = error.localizedDescription
                    searchStats = nil
                }
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

    // MARK: - Footer

    /// Compact status row at the bottom of the editor:
    /// - shows "Searching…" with a spinner while a search is in flight (results above
    ///   may be stale during this time)
    /// - shows the most recent search's stats once it completes
    /// - hides itself entirely when no search has been run
    /// Always-visible status row at the bottom of the editor. Three states:
    /// 1. `isSearching` → spinner + "Searching…" (with optional parenthetical when the
    ///    list above is showing stale results from a previous query)
    /// 2. `searchStats != nil` → most recent search's docs/vectors/time breakdown
    /// 3. otherwise → corpus stats (memory + task summary counts and total vectors)
    private var statsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                    Text(searchingFooterText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let stats = searchStats {
                    Image(systemName: "stopwatch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatStats(stats))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Image(systemName: "tray.full")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatCorpusStats())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))
        }
    }

    /// Footer text shown next to the spinner. The wording differs depending on whether
    /// the visible list is "previous results, slightly stale" or "the full list because
    /// no search has run yet."
    private var searchingFooterText: String {
        let activeMap = showTaskSummaries ? taskSummarySimilarities : memorySimilarities
        if activeMap.isEmpty {
            return "Searching…"
        } else {
            return "Searching… (results below are from previous query)"
        }
    }

    /// Idle-state footer text — describes the loaded corpus when no search is active.
    /// `embedded` is the count of entries whose stored vector is non-empty (i.e.
    /// searchable). Stale entries waiting for the migration pass to re-embed them
    /// have an empty `embedding` and won't contribute to semantic search hits.
    private func formatCorpusStats() -> String {
        let memCount = shared.storedMemories.count
        let memEmbedded = shared.storedMemories.reduce(0) { $0 + ($1.embedding.isEmpty ? 0 : 1) }
        let taskCount = shared.storedTaskSummaries.count
        let taskEmbedded = shared.storedTaskSummaries.reduce(0) { $0 + ($1.embedding.isEmpty ? 0 : 1) }
        let memLabel = memCount == 1 ? "memory" : "memories"
        let taskLabel = taskCount == 1 ? "task summary" : "task summaries"
        return "\(memCount) \(memLabel) (\(memEmbedded) embedded)  •  \(taskCount) \(taskLabel) (\(taskEmbedded) embedded)"
    }

    private func formatStats(_ stats: SearchStats) -> String {
        // Example: "59 docs / 231 vectors • 32ms total • 0.14ms/vector"
        let docsLabel = stats.totalDocCount == 1 ? "doc" : "docs"
        let vecLabel = stats.totalVectorCount == 1 ? "vector" : "vectors"
        let totalMs = String(format: "%.0f", stats.elapsedMs)
        let avgMs: String
        if stats.totalVectorCount == 0 {
            avgMs = "—"
        } else {
            avgMs = String(format: "%.2f", stats.avgMsPerVector)
        }
        return "\(stats.totalDocCount) \(docsLabel) / \(stats.totalVectorCount) \(vecLabel)  •  \(totalMs)ms total  •  \(avgMs)ms/vector"
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $showTaskSummaries) {
                Text("Memories (\(shared.storedMemories.count))").tag(false)
                Text("Tasks (\(shared.storedTaskSummaries.count))").tag(true)
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
        var result = shared.storedMemories
        if let source = filterSource {
            result = result.filter { $0.source == source }
        }
        if !searchText.isEmpty {
            if memorySimilarities.isEmpty {
                // Empty similarities map has two meanings: "first search hasn't run yet"
                // (show the full list as a placeholder so the UI doesn't blank out) vs.
                // "search completed and matched nothing" (return empty so the 'no matches'
                // empty-state can fire). `isSearching` distinguishes them.
                return isSearching ? result : []
            }
            let scored = result.filter { memorySimilarities[$0.id] != nil }
            return scored.sorted { (memorySimilarities[$0.id] ?? 0) > (memorySimilarities[$1.id] ?? 0) }
        }
        return result
    }

    @ViewBuilder
    private var memoryList: some View {
        let filtered = filteredMemories
        if let error = searchErrorMessage {
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if !searchText.isEmpty && !isSearching && filtered.isEmpty {
            // Only show "no matches" when the search has actually completed. While typing,
            // we keep showing stale results (or the full list on first search) so the UI
            // doesn't blank out between keystrokes.
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No memories matched “\(searchText)”. Try different keywords or a longer phrase.")
            )
        } else if shared.storedMemories.isEmpty && shared.memoryStore == nil {
            ContentUnavailableView(
                "Memory Store Not Loaded",
                systemImage: "play.circle",
                description: Text("Start a session from any window's toolbar to load memories from disk.")
            )
        } else if shared.storedMemories.isEmpty {
            ContentUnavailableView(
                "No Memories Saved",
                systemImage: "brain",
                description: Text("Memories will appear here as they're saved by you or the agents.")
            )
        } else if filterSource != nil && searchText.isEmpty && filtered.isEmpty {
            ContentUnavailableView(
                "No Matching Memories",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No memories from this source. Change the Source filter to see other memories.")
            )
        } else {
            List {
                ForEach(filtered) { memory in
                    if editingMemoryID == memory.id {
                        editRow(memory: memory)
                    } else {
                        memoryRow(memory: memory)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func memoryRow(memory: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                MarkdownText(content: memory.content, baseFont: .body)
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

            // Tag row only renders when there's at least one tag — an empty HStack with
            // just a Spacer leaves a thin gap that looks like a layout bug.
            if !memory.tags.isEmpty {
                HStack(spacing: 8) {
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
                    Spacer()
                }
            }

            // Row 1: created + last update (if any)
            HStack(spacing: 8) {
                Spacer()
                Text("Created \(formatDateTime(memory.createdAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let updatedAt = memory.lastUpdatedAt, let updatedBy = memory.lastUpdatedBy {
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Updated \(formatDateTime(updatedAt)) by \(updatedBy.displayLabel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Row 2: retrieval stats (only when the memory has been retrieved at least once)
            HStack(spacing: 8) {
                Spacer()
                if let retrievedAt = memory.lastRetrievedAt {
                    Text("Last retrieved \(formatDateTime(retrievedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(memory.retrievalCount) retrieval\(memory.retrievalCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Never retrieved by an agent")
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
                    Task { await shared.deleteMemory(id: memory.id) }
                }
                .controlSize(.small)
                .foregroundStyle(.red)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    /// Compact "Apr 8, 14:32" date+time formatting used by the editor's stats rows.
    private func formatDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
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
                            try await shared.updateMemory(
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
            if taskSummarySimilarities.isEmpty {
                // Same logic as `filteredMemories`: distinguish "first search not yet
                // complete" (show the full list as a placeholder) from "search completed
                // with zero results" (return empty to surface the 'no matches' state).
                return isSearching ? shared.storedTaskSummaries : []
            }
            let scored = shared.storedTaskSummaries.filter { taskSummarySimilarities[$0.id] != nil }
            return scored.sorted { (taskSummarySimilarities[$0.id] ?? 0) > (taskSummarySimilarities[$1.id] ?? 0) }
        }
        return shared.storedTaskSummaries
    }

    @ViewBuilder
    private var taskSummaryList: some View {
        let filtered = filteredTaskSummaries
        if let error = searchErrorMessage {
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if !searchText.isEmpty && !isSearching && filtered.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No tasks matched “\(searchText)”. Try different keywords or a longer phrase.")
            )
        } else if shared.storedTaskSummaries.isEmpty && shared.memoryStore == nil {
            ContentUnavailableView(
                "Memory Store Not Loaded",
                systemImage: "play.circle",
                description: Text("Start a session from any window's toolbar to load task summaries from disk.")
            )
        } else if shared.storedTaskSummaries.isEmpty {
            ContentUnavailableView(
                "No Tasks Indexed",
                systemImage: "doc.text",
                description: Text("Tasks become searchable after they complete or fail and a summary is generated.")
            )
        } else {
            List {
                ForEach(filtered) { summary in
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

                        MarkdownText(content: summary.summary, baseFont: .callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        // ID on the lower left (matching the Task Details window),
                        // creation date of the actual task on the lower right.
                        HStack(spacing: 8) {
                            Text("ID: \(summary.id.uuidString)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Spacer()
                            Text("Created \(formatDateTime(summary.taskCreatedAt))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
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

    private func similarityColor(_ score: Double) -> Color {
        if score >= 0.80 { return .green }
        if score >= 0.70 { return .yellow }
        if score >= 0.60 { return .orange }
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
        case .interrupted: return .yellow
        }
    }
}

private extension MemoryEntry.UpdateSource {
    /// Capitalized label used in the Memory editor's "Updated … by …" stat row.
    var displayLabel: String {
        switch self {
        case .user: return "User"
        case .system: return "System"
        }
    }
}
