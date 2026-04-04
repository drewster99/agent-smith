import Foundation

/// Search result pairing a memory with its similarity score.
public struct MemorySearchResult: Sendable {
    public let memory: MemoryEntry
    public let similarity: Double
}

/// Search result pairing a task summary with its similarity score.
public struct TaskSummarySearchResult: Sendable {
    public let summary: TaskSummaryEntry
    public let similarity: Double
}

/// Combined search results from both memory and task summary corpora.
public struct SemanticSearchResults: Sendable {
    public let memories: [MemorySearchResult]
    public let taskSummaries: [TaskSummarySearchResult]

    /// True when both result sets are empty.
    public var isEmpty: Bool { memories.isEmpty && taskSummaries.isEmpty }
}

/// Lightweight struct for attaching relevant memories to tasks.
public struct RelevantMemory: Codable, Sendable {
    public let content: String
    public let tags: [String]
    public let similarity: Double

    public init(content: String, tags: [String], similarity: Double) {
        self.content = content
        self.tags = tags
        self.similarity = similarity
    }
}

/// Lightweight struct for attaching relevant prior task summaries to tasks.
public struct RelevantPriorTask: Codable, Sendable {
    public let taskID: UUID
    public let title: String
    public let summary: String
    public let similarity: Double

    public init(taskID: UUID, title: String, summary: String, similarity: Double) {
        self.taskID = taskID
        self.title = title
        self.summary = summary
        self.similarity = similarity
    }

    /// Decodes a `RelevantPriorTask`, falling back to a random UUID for `taskID`
    /// when the key is absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        similarity = try c.decode(Double.self, forKey: .similarity)
    }
}

/// Thread-safe store for semantic memories and task summary embeddings.
///
/// Uses **multi-vector sentence embeddings** for search. Each document (memory or task
/// summary) is split into individual sentences, each embedded separately. Search computes
/// the maximum cosine similarity across all (query sentence, document sentence) pairs.
/// This aligns with how NLEmbedding was trained (sentence-level input) and produces
/// much better topical matching than embedding an entire document as one vector.
public actor MemoryStore {
    private var memories: [UUID: MemoryEntry] = [:]
    private var taskSummaries: [UUID: TaskSummaryEntry] = [:]
    private let embeddingService: EmbeddingService
    private var onChange: (@Sendable () -> Void)?

    public init(embeddingService: EmbeddingService) {
        self.embeddingService = embeddingService
    }

    /// Registers a callback fired whenever memories or task summaries change.
    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    // MARK: - Memory Operations

    /// Saves a new memory, splitting into sentences and embedding each one.
    @discardableResult
    public func save(
        content: String,
        source: MemoryEntry.Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil
    ) throws -> MemoryEntry {
        let embeddings = try embeddingService.splitAndEmbed(content)
        let entry = MemoryEntry(
            content: content,
            embeddings: embeddings,
            source: source,
            tags: tags,
            sourceTaskID: sourceTaskID
        )
        memories[entry.id] = entry
        onChange?()
        return entry
    }

    /// Updates an existing memory's content and/or tags.
    ///
    /// Re-embeds the content if it changed. Returns the updated entry, or nil if the ID wasn't found.
    @discardableResult
    public func update(id: UUID, content: String? = nil, tags: [String]? = nil) throws -> MemoryEntry? {
        guard let existing = memories[id] else { return nil }
        let newContent = content ?? existing.content
        let newTags = tags ?? existing.tags
        let newEmbeddings: [[Double]]
        if content != nil && content != existing.content {
            newEmbeddings = try embeddingService.splitAndEmbed(newContent)
        } else {
            newEmbeddings = existing.embeddings
        }
        let updated = MemoryEntry(
            id: existing.id,
            content: newContent,
            embeddings: newEmbeddings,
            source: existing.source,
            tags: newTags,
            sourceTaskID: existing.sourceTaskID,
            createdAt: existing.createdAt,
            lastAccessedAt: existing.lastAccessedAt
        )
        memories[id] = updated
        onChange?()
        return updated
    }

    /// Deletes a memory by ID.
    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard memories.removeValue(forKey: id) != nil else { return false }
        onChange?()
        return true
    }

    /// All memories, newest first.
    public func allMemories() -> [MemoryEntry] {
        memories.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Total number of stored memories.
    public var memoryCount: Int { memories.count }

    // MARK: - Task Summary Operations

    /// Composes the embedding source text from all available task fields.
    ///
    /// Includes title, description, summary, result, commentary, and progress updates
    /// so the embedding captures the full topical signal of the task.
    public static func composeEmbeddingText(task: AgentTask, summary: String) -> String {
        var parts: [String] = []
        parts.append(task.title)
        parts.append(task.description)
        parts.append(summary)
        if let result = task.result, !result.isEmpty {
            // Cap result to avoid excessive sentence count.
            parts.append(String(result.prefix(2000)))
        }
        if let commentary = task.commentary, !commentary.isEmpty {
            parts.append(commentary)
        }
        if !task.updates.isEmpty {
            let updateText = task.updates.map(\.message).joined(separator: " ")
            parts.append(String(updateText.prefix(1000)))
        }
        return parts.joined(separator: "\n")
    }

    /// Saves a task summary, splitting the rich composite text into sentences
    /// and embedding each one for multi-vector search.
    @discardableResult
    public func saveTaskSummary(
        task: AgentTask,
        summary: String,
        status: AgentTask.Status
    ) throws -> TaskSummaryEntry {
        let embeddingText = Self.composeEmbeddingText(task: task, summary: summary)
        let embeddings = try embeddingService.splitAndEmbed(embeddingText)
        let entry = TaskSummaryEntry(
            id: task.id,
            title: task.title,
            summary: summary,
            embeddingSourceText: embeddingText,
            embeddings: embeddings,
            status: status
        )
        taskSummaries[task.id] = entry
        onChange?()
        return entry
    }

    /// All task summaries, newest first.
    public func allTaskSummaries() -> [TaskSummaryEntry] {
        taskSummaries.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Total number of stored task summaries.
    public var taskSummaryCount: Int { taskSummaries.count }

    // MARK: - Search

    /// Searches memories by max sentence-pair cosine similarity to the query.
    ///
    /// The query is split into sentences and each is compared against each
    /// sentence in each memory. The best pair determines the score.
    /// Updates `lastAccessedAt` on returned results.
    public func searchMemories(
        query: String,
        limit: Int = 5,
        threshold: Double = 0.10
    ) throws -> [MemorySearchResult] {
        let queryEmbeddings = try embeddingService.splitAndEmbed(query)
        return searchMemories(queryEmbeddings: queryEmbeddings, limit: limit, threshold: threshold)
    }

    /// Searches memories using pre-computed query sentence embeddings.
    private func searchMemories(
        queryEmbeddings: [[Double]],
        limit: Int,
        threshold: Double
    ) -> [MemorySearchResult] {
        var results: [MemorySearchResult] = []
        for entry in memories.values {
            let similarity = EmbeddingService.maxSimilarity(
                query: queryEmbeddings, document: entry.embeddings
            )
            if similarity >= threshold {
                results.append(MemorySearchResult(memory: entry, similarity: similarity))
            }
        }

        results.sort { $0.similarity > $1.similarity }
        let topResults = Array(results.prefix(limit))

        // Update lastAccessedAt for returned memories.
        let now = Date()
        for result in topResults {
            if var entry = memories[result.memory.id] {
                entry.lastAccessedAt = now
                memories[entry.id] = entry
            }
        }

        return topResults
    }

    /// Searches task summaries by max sentence-pair cosine similarity to the query.
    public func searchTaskSummaries(
        query: String,
        limit: Int = 5,
        threshold: Double = 0.10
    ) throws -> [TaskSummarySearchResult] {
        let queryEmbeddings = try embeddingService.splitAndEmbed(query)
        return searchTaskSummaries(queryEmbeddings: queryEmbeddings, limit: limit, threshold: threshold)
    }

    /// Searches task summaries using pre-computed query sentence embeddings.
    private func searchTaskSummaries(
        queryEmbeddings: [[Double]],
        limit: Int,
        threshold: Double
    ) -> [TaskSummarySearchResult] {
        var results: [TaskSummarySearchResult] = []
        for entry in taskSummaries.values {
            let similarity = EmbeddingService.maxSimilarity(
                query: queryEmbeddings, document: entry.embeddings
            )
            if similarity >= threshold {
                results.append(TaskSummarySearchResult(summary: entry, similarity: similarity))
            }
        }

        results.sort { $0.similarity > $1.similarity }
        return Array(results.prefix(limit))
    }

    /// Searches both memories and task summaries using tiered relevance thresholds.
    ///
    /// With multi-vector sentence matching, scores are more discriminating than
    /// single-vector — a genuine match between specific sentences scores high
    /// while unrelated content scores lower.
    /// - Tier 1 (>=0.65): up to 3 results — strong sentence-level matches
    /// - Tier 2 (0.55–0.65): up to 2 results, only if tier 1 is empty
    /// Maximum 4 results total across both memories and task summaries.
    public func searchAll(
        query: String,
        memoryLimit: Int = 3,
        taskLimit: Int = 3
    ) throws -> SemanticSearchResults {
        let queryEmbeddings = try embeddingService.splitAndEmbed(query)
        let allMemories = searchMemories(queryEmbeddings: queryEmbeddings, limit: memoryLimit, threshold: 0.55)
        let allTasks = searchTaskSummaries(queryEmbeddings: queryEmbeddings, limit: taskLimit, threshold: 0.55)

        enum Candidate {
            case memory(Int)
            case task(Int)
        }
        var candidates: [(similarity: Double, candidate: Candidate)] = []
        for (i, m) in allMemories.enumerated() {
            candidates.append((m.similarity, .memory(i)))
        }
        for (i, t) in allTasks.enumerated() {
            candidates.append((t.similarity, .task(i)))
        }
        candidates.sort { $0.similarity > $1.similarity }

        let tier1 = candidates.filter { $0.similarity >= 0.65 }
        let tier2 = candidates.filter { $0.similarity >= 0.55 && $0.similarity < 0.65 }

        let selected: ArraySlice<(similarity: Double, candidate: Candidate)>
        if !tier1.isEmpty {
            selected = tier1.prefix(3)
        } else if !tier2.isEmpty {
            selected = tier2.prefix(2)
        } else {
            return SemanticSearchResults(memories: [], taskSummaries: [])
        }

        var memoryResults: [MemorySearchResult] = []
        var taskResults: [TaskSummarySearchResult] = []
        for item in selected.prefix(4) {
            switch item.candidate {
            case .memory(let i): memoryResults.append(allMemories[i])
            case .task(let i): taskResults.append(allTasks[i])
            }
        }

        return SemanticSearchResults(memories: memoryResults, taskSummaries: taskResults)
    }

    // MARK: - Re-embedding

    /// Re-embeds all memories by splitting content into sentences.
    /// Returns the number of memories re-embedded.
    @discardableResult
    public func reembedAllMemories() throws -> Int {
        var count = 0
        for (id, entry) in memories {
            let newEmbeddings = try embeddingService.splitAndEmbed(entry.content)
            memories[id] = MemoryEntry(
                id: entry.id,
                content: entry.content,
                embeddings: newEmbeddings,
                source: entry.source,
                tags: entry.tags,
                sourceTaskID: entry.sourceTaskID,
                createdAt: entry.createdAt,
                lastAccessedAt: entry.lastAccessedAt
            )
            count += 1
        }
        if count > 0 { onChange?() }
        return count
    }

    /// Re-embeds task summaries using full task data, split into sentences.
    ///
    /// Builds rich embedding text from all task fields, then splits into
    /// sentences for multi-vector embedding. Updates `embeddingSourceText`.
    @discardableResult
    public func reembedTaskSummariesFromTasks(_ tasks: [AgentTask]) throws -> Int {
        var count = 0
        for task in tasks {
            guard let existing = taskSummaries[task.id] else { continue }
            let embeddingText = Self.composeEmbeddingText(task: task, summary: existing.summary)
            let newEmbeddings = try embeddingService.splitAndEmbed(embeddingText)
            taskSummaries[task.id] = TaskSummaryEntry(
                id: existing.id,
                title: existing.title,
                summary: existing.summary,
                embeddingSourceText: embeddingText,
                embeddings: newEmbeddings,
                status: existing.status,
                createdAt: existing.createdAt
            )
            count += 1
        }
        if count > 0 { onChange?() }
        return count
    }

    // MARK: - Persistence Support

    /// Restores memories and task summaries from persisted data (e.g., on app launch).
    public func restore(memories: [MemoryEntry], taskSummaries: [TaskSummaryEntry]) {
        for memory in memories {
            self.memories[memory.id] = memory
        }
        for summary in taskSummaries {
            self.taskSummaries[summary.id] = summary
        }
    }

    /// Removes all memories and task summaries.
    public func clear() {
        memories.removeAll()
        taskSummaries.removeAll()
        onChange?()
    }
}
