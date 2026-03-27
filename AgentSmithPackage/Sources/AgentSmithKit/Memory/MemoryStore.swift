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
    public let title: String
    public let summary: String
    public let similarity: Float

    public init(title: String, summary: String, similarity: Float) {
        self.title = title
        self.summary = summary
        self.similarity = similarity
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

    /// Searches both memories and task summaries, returning combined results.
    ///
    /// Memories are prioritized (searched first, get dedicated limit).
    /// - Parameters:
    ///   - query: Natural language search text.
    ///   - memoryLimit: Maximum memory results.
    ///   - taskLimit: Maximum task summary results.
    ///   - threshold: Minimum cosine similarity to include.
    /// - Returns: Combined search results from both corpora.
    public func searchAll(
        query: String,
        memoryLimit: Int = 3,
        taskLimit: Int = 3,
        threshold: Float = 0.3
    ) throws -> SemanticSearchResults {
        let memoryResults = try searchMemories(query: query, limit: memoryLimit, threshold: threshold)
        let taskResults = try searchTaskSummaries(query: query, limit: taskLimit, threshold: threshold)
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
