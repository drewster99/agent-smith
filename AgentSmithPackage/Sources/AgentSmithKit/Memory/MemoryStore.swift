import Foundation

/// Search result pairing a memory with its similarity score.
public struct MemorySearchResult: Sendable {
    public let memory: MemoryEntry
    public let similarity: Float
}

/// Search result pairing a task summary with its similarity score.
public struct TaskSummarySearchResult: Sendable {
    public let summary: TaskSummaryEntry
    public let similarity: Float
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
    public let similarity: Float

    public init(content: String, tags: [String], similarity: Float) {
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
    public let similarity: Float

    public init(taskID: UUID, title: String, summary: String, similarity: Float) {
        self.taskID = taskID
        self.title = title
        self.summary = summary
        self.similarity = similarity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        similarity = try c.decode(Float.self, forKey: .similarity)
    }
}

/// Thread-safe store for semantic memories and task summary embeddings.
///
/// Owns the `EmbeddingService` and provides search over both corpora using cosine similarity.
/// Follows the actor pattern used by `TaskStore` and `MessageChannel`.
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

    /// Saves a new memory, embedding the content automatically.
    @discardableResult
    public func save(
        content: String,
        source: MemoryEntry.Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil
    ) throws -> MemoryEntry {
        let embedding = try embeddingService.embed(content)
        let entry = MemoryEntry(
            content: content,
            embedding: embedding,
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
        let newEmbedding: [Float]
        if content != nil && content != existing.content {
            newEmbedding = try embeddingService.embed(newContent)
        } else {
            newEmbedding = existing.embedding
        }
        let updated = MemoryEntry(
            id: existing.id,
            content: newContent,
            embedding: newEmbedding,
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

    /// Saves a task summary, embedding the summary text automatically.
    @discardableResult
    public func saveTaskSummary(
        taskID: UUID,
        title: String,
        summary: String,
        status: AgentTask.Status
    ) throws -> TaskSummaryEntry {
        let embedding = try embeddingService.embed(summary)
        let entry = TaskSummaryEntry(
            id: taskID,
            title: title,
            summary: summary,
            embedding: embedding,
            status: status
        )
        taskSummaries[taskID] = entry
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

    /// Searches memories by semantic similarity to the query.
    ///
    /// Updates `lastAccessedAt` on returned results.
    /// - Parameters:
    ///   - query: Natural language search text.
    ///   - limit: Maximum number of results to return.
    ///   - threshold: Minimum cosine similarity to include (0.0–1.0).
    /// - Returns: Results sorted by descending similarity.
    public func searchMemories(
        query: String,
        limit: Int = 5,
        threshold: Float = 0.3
    ) throws -> [MemorySearchResult] {
        let queryEmbedding = try embeddingService.embed(query)

        var results: [MemorySearchResult] = []
        for entry in memories.values {
            let similarity = EmbeddingService.cosineSimilarity(queryEmbedding, entry.embedding)
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

    /// Searches task summaries by semantic similarity to the query.
    ///
    /// - Parameters:
    ///   - query: Natural language search text.
    ///   - limit: Maximum number of results to return.
    ///   - threshold: Minimum cosine similarity to include (0.0–1.0).
    /// - Returns: Results sorted by descending similarity.
    public func searchTaskSummaries(
        query: String,
        limit: Int = 5,
        threshold: Float = 0.3
    ) throws -> [TaskSummarySearchResult] {
        let queryEmbedding = try embeddingService.embed(query)

        var results: [TaskSummarySearchResult] = []
        for entry in taskSummaries.values {
            let similarity = EmbeddingService.cosineSimilarity(queryEmbedding, entry.embedding)
            if similarity >= threshold {
                results.append(TaskSummarySearchResult(summary: entry, similarity: similarity))
            }
        }

        results.sort { $0.similarity > $1.similarity }
        return Array(results.prefix(limit))
    }

    /// Searches both memories and task summaries using tiered relevance thresholds.
    ///
    /// Local embedding models produce lower cosine similarity scores than cloud models,
    /// so thresholds are calibrated for local embeddings (~0.40–0.98 range):
    /// - Tier 1 (≥0.55): up to 3 results
    /// - Tier 2 (0.45–0.55): up to 2 results, only if tier 1 is empty
    /// - Tier 3 (0.35–0.45): up to 1 result, only if tiers 1 and 2 are empty
    /// Maximum 4 results total across both memories and task summaries.
    public func searchAll(
        query: String,
        memoryLimit: Int = 3,
        taskLimit: Int = 3
    ) throws -> SemanticSearchResults {
        let allMemories = try searchMemories(query: query, limit: memoryLimit, threshold: 0.35)
        let allTasks = try searchTaskSummaries(query: query, limit: taskLimit, threshold: 0.35)

        enum Candidate {
            case memory(Int)
            case task(Int)
        }
        var candidates: [(similarity: Float, candidate: Candidate)] = []
        for (i, m) in allMemories.enumerated() {
            candidates.append((m.similarity, .memory(i)))
        }
        for (i, t) in allTasks.enumerated() {
            candidates.append((t.similarity, .task(i)))
        }
        candidates.sort { $0.similarity > $1.similarity }

        let tier1 = candidates.filter { $0.similarity >= 0.55 }
        let tier2 = candidates.filter { $0.similarity >= 0.45 && $0.similarity < 0.55 }
        let tier3 = candidates.filter { $0.similarity >= 0.35 && $0.similarity < 0.45 }

        let selected: ArraySlice<(similarity: Float, candidate: Candidate)>
        if !tier1.isEmpty {
            selected = tier1.prefix(3)
        } else if !tier2.isEmpty {
            selected = tier2.prefix(2)
        } else if !tier3.isEmpty {
            selected = tier3.prefix(1)
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
