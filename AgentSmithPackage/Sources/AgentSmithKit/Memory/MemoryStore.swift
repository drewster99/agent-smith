import Foundation
import SemanticSearch

/// Search result pairing a memory with its scoring breakdown.
///
/// `similarity` is the raw cosine similarity from the embedding (kept under
/// the historical name so existing display code that formats it as a percentage stays
/// meaningful). `textScore` and `rrfScore` are additive: callers can ignore them, but
/// the search ordering returned by `MemoryStore` is by `rrfScore` descending.
public struct MemorySearchResult: Sendable {
    public let memory: MemoryEntry
    /// Cosine similarity between the query and the document, in `[-1, 1]`.
    public let similarity: Double
    /// Fraction of distinct query keywords found as whole tokens in the memory content, [0, 1].
    public let textScore: Double
    /// Reciprocal Rank Fusion score combining the semantic and lexical rankings (k=60).
    /// Used by `MemoryStore` to order results; higher means better combined match.
    public let rrfScore: Double
}

/// Search result pairing a task summary with its scoring breakdown. See
/// `MemorySearchResult` for the meaning of each score field.
public struct TaskSummarySearchResult: Sendable {
    public let summary: TaskSummaryEntry
    public let similarity: Double
    public let textScore: Double
    public let rrfScore: Double
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
/// Uses **single-vector embeddings** produced by `SemanticSearchEngine` (Qwen3 via MLX
/// by default). Each document is embedded as one L2-normalized vector and search
/// scores it against the query with a single cosine. Multi-vector retrieval (the
/// previous design with `splitAndEmbed`) was a workaround for `NLEmbedding`'s
/// sentence-only training and is no longer needed.
public actor MemoryStore {
    private var memories: [UUID: MemoryEntry] = [:]
    private var taskSummaries: [UUID: TaskSummaryEntry] = [:]
    private let engine: SemanticSearchEngine
    private var onChange: (@Sendable () -> Void)?

    public init(engine: SemanticSearchEngine) {
        self.engine = engine
    }

    /// Identifier of the embedding model the store stamps onto new entries.
    /// Read-through to the engine's nonisolated `model.identifier`.
    public nonisolated var currentModelID: String {
        engine.model.identifier
    }

    /// Registers a callback fired whenever memories or task summaries change.
    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    // MARK: - Memory Operations

    /// Saves a new memory, embedding the content as a single L2-normalized vector
    /// using the current `SemanticSearchEngine`.
    @discardableResult
    public func save(
        content: String,
        source: MemoryEntry.Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil
    ) async throws -> MemoryEntry {
        let vector = try await engine.embed(content)
        let entry = MemoryEntry(
            content: content,
            embedding: vector,
            embeddingModelID: currentModelID,
            source: source,
            tags: tags,
            sourceTaskID: sourceTaskID
        )
        memories[entry.id] = entry
        onChange?()
        return entry
    }

    /// Updates an existing memory's content and/or tags. Records who performed the edit
    /// in the entry's `lastUpdatedAt` / `lastUpdatedBy` fields. Re-embeds when the content
    /// changed. Returns the updated entry, or nil if the ID wasn't found.
    @discardableResult
    public func update(
        id: UUID,
        content: String? = nil,
        tags: [String]? = nil,
        updatedBy: MemoryEntry.UpdateSource
    ) async throws -> MemoryEntry? {
        guard let existing = memories[id] else { return nil }
        let newContent = content ?? existing.content
        let newTags = tags ?? existing.tags
        let newEmbedding: [Float]
        let newModelID: String?
        if content != nil && content != existing.content {
            newEmbedding = try await engine.embed(newContent)
            newModelID = currentModelID
        } else {
            newEmbedding = existing.embedding
            newModelID = existing.embeddingModelID
        }
        let updated = MemoryEntry(
            id: existing.id,
            content: newContent,
            embedding: newEmbedding,
            embeddingModelID: newModelID,
            source: existing.source,
            tags: newTags,
            sourceTaskID: existing.sourceTaskID,
            createdAt: existing.createdAt,
            lastRetrievedAt: existing.lastRetrievedAt,
            retrievalCount: existing.retrievalCount,
            lastUpdatedAt: Date(),
            lastUpdatedBy: updatedBy
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
    /// so the embedding captures the full topical signal of the task. No length caps —
    /// long results and update logs are embedded in full so they remain searchable.
    public static func composeEmbeddingText(task: AgentTask, summary: String) -> String {
        var parts: [String] = []
        parts.append(task.title)
        parts.append(task.description)
        parts.append(summary)
        if let result = task.result, !result.isEmpty {
            parts.append(result)
        }
        if let commentary = task.commentary, !commentary.isEmpty {
            parts.append(commentary)
        }
        if !task.updates.isEmpty {
            let updateText = task.updates.map(\.message).joined(separator: " ")
            parts.append(updateText)
        }
        return parts.joined(separator: "\n")
    }

    /// Saves a task summary, embedding the rich composite text as a single vector.
    /// Captures the task's original `createdAt` so the editor can show "when the task
    /// was asked for" rather than "when the summary was generated."
    @discardableResult
    public func saveTaskSummary(
        task: AgentTask,
        summary: String,
        status: AgentTask.Status
    ) async throws -> TaskSummaryEntry {
        let embeddingText = Self.composeEmbeddingText(task: task, summary: summary)
        let vector = try await engine.embed(embeddingText)
        let entry = TaskSummaryEntry(
            id: task.id,
            title: task.title,
            summary: summary,
            embeddingSourceText: embeddingText,
            embedding: vector,
            embeddingModelID: currentModelID,
            status: status,
            taskCreatedAt: task.createdAt
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

    // MARK: - Search scoring

    /// `k` constant for Reciprocal Rank Fusion. The standard literature value is 60 —
    /// it dampens the influence of any single ranking source so high ranks dominate
    /// without completely shutting out lower-ranked items.
    private static let rrfK: Double = 60

    /// Quality floor used by `searchAll` to drop pure-noise candidates before RRF ranking.
    /// A document must score at least this much on EITHER signal (semantic OR text) to be
    /// considered. Calibrated against `NLEmbedding` cosines and may need recalibration now
    /// that we're on Qwen3.
    private static let searchAllNoiseFloor: Double = 0.55

    /// Common English stopwords stripped from query tokens before text scoring.
    private static let englishStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be", "been", "being",
        "of", "in", "on", "at", "to", "for", "with", "from", "by", "as", "into", "out", "up", "down",
        "over", "under", "between", "through", "about",
        "this", "that", "these", "those", "it", "its",
        "what", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "do", "does", "did", "done", "doing",
        "can", "could", "would", "should", "will", "may", "might", "must", "shall",
        "i", "me", "my", "mine", "you", "your", "yours", "we", "us", "our", "ours",
        "they", "them", "their", "theirs", "he", "she", "him", "her", "his", "hers",
        "if", "then", "than", "so", "no", "not", "yes", "too", "very", "just",
        "have", "has", "had", "having",
        "any", "all", "some", "each", "every", "both", "few", "more", "most", "other", "such",
        "only", "own", "same"
    ]

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                if current.count >= 2 { tokens.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { tokens.append(current) }
        return tokens
    }

    private static func queryTokenSet(from query: String) -> Set<String> {
        Set(tokenize(query).filter { !englishStopwords.contains($0) })
    }

    private static func textScore(queryTokens: Set<String>, document: String) -> Double {
        guard !queryTokens.isEmpty else { return 0.0 }
        let documentTokens = Set(tokenize(document))
        let matched = queryTokens.intersection(documentTokens)
        return Double(matched.count) / Double(queryTokens.count)
    }

    private static func reciprocalRankFusion(
        semanticScores: [Double],
        textScores: [Double]
    ) -> [Double] {
        precondition(semanticScores.count == textScores.count)
        let count = semanticScores.count
        guard count > 0 else { return [] }

        let semanticRanks = ranksFromScores(semanticScores)
        let textRanks = ranksFromScores(textScores)

        var rrf = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let sRank = Double(semanticRanks[i])
            let lRank = Double(textRanks[i])
            rrf[i] = 1.0 / (rrfK + sRank) + 1.0 / (rrfK + lRank)
        }
        return rrf
    }

    private static func ranksFromScores(_ scores: [Double]) -> [Int] {
        let count = scores.count
        guard count > 0 else { return [] }
        let sortedIndices = (0..<count).sorted { scores[$0] > scores[$1] }
        var ranks = [Int](repeating: 0, count: count)
        var lastScore: Double = .nan
        var lastRank = 0
        for (position, originalIdx) in sortedIndices.enumerated() {
            let score = scores[originalIdx]
            let rank: Int
            if score == lastScore {
                rank = lastRank
            } else {
                rank = position + 1
                lastScore = score
                lastRank = rank
            }
            ranks[originalIdx] = rank
        }
        return ranks
    }

    /// Returns true when an entry's stored embedding can be compared to the given
    /// query vector — the model ID matches AND the dimensions agree. Used to skip
    /// stale entries during the migration window before re-embed completes.
    private func isComparable(embedding: [Float], modelID: String?, queryDim: Int) -> Bool {
        guard let modelID, modelID == currentModelID else { return false }
        guard !embedding.isEmpty, embedding.count == queryDim else { return false }
        return true
    }

    // MARK: - Search

    /// Searches memories using Reciprocal Rank Fusion of semantic similarity and keyword
    /// overlap. The `threshold` parameter is a noise floor on `MAX(semantic, text)`.
    public func searchMemories(
        query: String,
        limit: Int = 5,
        threshold: Double = 0.10
    ) async throws -> [MemorySearchResult] {
        let start = Date()
        let queryVector = try await engine.embed(query)
        let queryTokens = Self.queryTokenSet(from: query)
        let results = searchMemoriesInternal(
            queryVector: queryVector,
            queryTokens: queryTokens,
            limit: limit,
            threshold: threshold
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[MemoryStore] searchMemories: \(results.count) results from \(memories.count) memories in \(ms)ms (query: \(query.prefix(60)))")
        return results
    }

    private func searchMemoriesInternal(
        queryVector: [Float],
        queryTokens: Set<String>,
        limit: Int,
        threshold: Double
    ) -> [MemorySearchResult] {
        var entryRefs: [MemoryEntry] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []
        for entry in memories.values {
            let semantic: Double
            if isComparable(embedding: entry.embedding, modelID: entry.embeddingModelID, queryDim: queryVector.count) {
                semantic = Double(VectorMath.dotProduct(queryVector, entry.embedding))
            } else {
                semantic = 0
            }
            let text = Self.textScore(queryTokens: queryTokens, document: entry.content)
            if max(semantic, text) >= threshold {
                entryRefs.append(entry)
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }

        guard !entryRefs.isEmpty else { return [] }

        let rrfScores = Self.reciprocalRankFusion(
            semanticScores: semanticScores,
            textScores: textScores
        )

        var results: [MemorySearchResult] = []
        results.reserveCapacity(entryRefs.count)
        for i in 0..<entryRefs.count {
            results.append(MemorySearchResult(
                memory: entryRefs[i],
                similarity: semanticScores[i],
                textScore: textScores[i],
                rrfScore: rrfScores[i]
            ))
        }
        results.sort { $0.rrfScore > $1.rrfScore }
        return Array(results.prefix(limit))
    }

    public func searchTaskSummaries(
        query: String,
        limit: Int = 5,
        threshold: Double = 0.10
    ) async throws -> [TaskSummarySearchResult] {
        let start = Date()
        let queryVector = try await engine.embed(query)
        let queryTokens = Self.queryTokenSet(from: query)
        let results = searchTaskSummariesInternal(
            queryVector: queryVector,
            queryTokens: queryTokens,
            limit: limit,
            threshold: threshold
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[MemoryStore] searchTaskSummaries: \(results.count) results from \(taskSummaries.count) summaries in \(ms)ms (query: \(query.prefix(60)))")
        return results
    }

    private func searchTaskSummariesInternal(
        queryVector: [Float],
        queryTokens: Set<String>,
        limit: Int,
        threshold: Double
    ) -> [TaskSummarySearchResult] {
        var entryRefs: [TaskSummaryEntry] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []
        for entry in taskSummaries.values {
            let semantic: Double
            if isComparable(embedding: entry.embedding, modelID: entry.embeddingModelID, queryDim: queryVector.count) {
                semantic = Double(VectorMath.dotProduct(queryVector, entry.embedding))
            } else {
                semantic = 0
            }
            let text = Self.textScore(queryTokens: queryTokens, document: entry.embeddingSourceText)
            if max(semantic, text) >= threshold {
                entryRefs.append(entry)
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }

        guard !entryRefs.isEmpty else { return [] }

        let rrfScores = Self.reciprocalRankFusion(
            semanticScores: semanticScores,
            textScores: textScores
        )

        var results: [TaskSummarySearchResult] = []
        results.reserveCapacity(entryRefs.count)
        for i in 0..<entryRefs.count {
            results.append(TaskSummarySearchResult(
                summary: entryRefs[i],
                similarity: semanticScores[i],
                textScore: textScores[i],
                rrfScore: rrfScores[i]
            ))
        }
        results.sort { $0.rrfScore > $1.rrfScore }
        return Array(results.prefix(limit))
    }

    /// Searches both memories and task summaries jointly using Reciprocal Rank Fusion.
    public func searchAll(
        query: String,
        memoryLimit: Int = 3,
        taskLimit: Int = 3
    ) async throws -> SemanticSearchResults {
        let start = Date()
        let queryVector = try await engine.embed(query)
        let queryTokens = Self.queryTokenSet(from: query)

        enum CandidateRef {
            case memory(MemoryEntry)
            case task(TaskSummaryEntry)
        }
        var refs: [CandidateRef] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []

        for entry in memories.values {
            let semantic: Double
            if isComparable(embedding: entry.embedding, modelID: entry.embeddingModelID, queryDim: queryVector.count) {
                semantic = Double(VectorMath.dotProduct(queryVector, entry.embedding))
            } else {
                semantic = 0
            }
            let text = Self.textScore(queryTokens: queryTokens, document: entry.content)
            if max(semantic, text) >= Self.searchAllNoiseFloor {
                refs.append(.memory(entry))
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }
        for entry in taskSummaries.values {
            let semantic: Double
            if isComparable(embedding: entry.embedding, modelID: entry.embeddingModelID, queryDim: queryVector.count) {
                semantic = Double(VectorMath.dotProduct(queryVector, entry.embedding))
            } else {
                semantic = 0
            }
            let text = Self.textScore(queryTokens: queryTokens, document: entry.embeddingSourceText)
            if max(semantic, text) >= Self.searchAllNoiseFloor {
                refs.append(.task(entry))
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }

        guard !refs.isEmpty else {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("[MemoryStore] searchAll: 0 results in \(ms)ms (query: \(query.prefix(60)))")
            return SemanticSearchResults(memories: [], taskSummaries: [])
        }

        let rrfScores = Self.reciprocalRankFusion(
            semanticScores: semanticScores,
            textScores: textScores
        )

        let order = (0..<refs.count).sorted { rrfScores[$0] > rrfScores[$1] }

        let cap = min(4, max(memoryLimit, taskLimit) + min(memoryLimit, taskLimit))
        var memoryResults: [MemorySearchResult] = []
        var taskResults: [TaskSummarySearchResult] = []
        let retrievedAt = Date()
        var trackedAnyRetrieval = false
        for idx in order.prefix(cap) {
            switch refs[idx] {
            case .memory(let entry):
                memoryResults.append(MemorySearchResult(
                    memory: entry,
                    similarity: semanticScores[idx],
                    textScore: textScores[idx],
                    rrfScore: rrfScores[idx]
                ))
                if var stored = memories[entry.id] {
                    stored.lastRetrievedAt = retrievedAt
                    stored.retrievalCount += 1
                    memories[entry.id] = stored
                    trackedAnyRetrieval = true
                }
            case .task(let entry):
                taskResults.append(TaskSummarySearchResult(
                    summary: entry,
                    similarity: semanticScores[idx],
                    textScore: textScores[idx],
                    rrfScore: rrfScores[idx]
                ))
            }
        }

        if trackedAnyRetrieval { onChange?() }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[MemoryStore] searchAll: \(memoryResults.count) memories + \(taskResults.count) tasks in \(ms)ms (query: \(query.prefix(60)))")
        return SemanticSearchResults(memories: memoryResults, taskSummaries: taskResults)
    }

    // MARK: - Re-embedding

    /// Re-embeds memories whose `embeddingModelID` doesn't match the current model.
    /// Skips entries that are deleted or modified mid-pass. Yields between iterations
    /// (the actor is released by `await`), so concurrent saves/searches still get
    /// served while migration is in flight.
    @discardableResult
    public func reembedStaleMemories() async throws -> Int {
        let target = currentModelID
        let staleIDs = memories.compactMap { (id, entry) -> UUID? in
            entry.embeddingModelID == target ? nil : id
        }

        var count = 0
        for id in staleIDs {
            guard let snapshot = memories[id], snapshot.embeddingModelID != target else {
                continue
            }
            let vector = try await engine.embed(snapshot.content)
            // After the await, re-check the entry — it may have been deleted or
            // updated under us. Only write back if the entry still exists with the
            // same content we embedded.
            guard let stillCurrent = memories[id], stillCurrent.content == snapshot.content else {
                continue
            }
            let updated = MemoryEntry(
                id: stillCurrent.id,
                content: stillCurrent.content,
                embedding: vector,
                embeddingModelID: target,
                source: stillCurrent.source,
                tags: stillCurrent.tags,
                sourceTaskID: stillCurrent.sourceTaskID,
                createdAt: stillCurrent.createdAt,
                lastRetrievedAt: stillCurrent.lastRetrievedAt,
                retrievalCount: stillCurrent.retrievalCount,
                lastUpdatedAt: stillCurrent.lastUpdatedAt,
                lastUpdatedBy: stillCurrent.lastUpdatedBy
            )
            memories[id] = updated
            count += 1
        }
        if count > 0 { onChange?() }
        return count
    }

    /// Re-embeds task summaries whose `embeddingModelID` doesn't match the current model.
    /// Pulls fresh task data from the provided `tasks` array so the composite
    /// `embeddingSourceText` includes any updates that landed since the summary was
    /// originally generated.
    @discardableResult
    public func reembedStaleTaskSummaries(tasks: [AgentTask]) async throws -> Int {
        let target = currentModelID
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let staleIDs = taskSummaries.compactMap { (id, entry) -> UUID? in
            entry.embeddingModelID == target ? nil : id
        }

        var count = 0
        for id in staleIDs {
            guard let snapshot = taskSummaries[id], snapshot.embeddingModelID != target else {
                continue
            }
            guard let task = tasksByID[id] else { continue }
            let embeddingText = Self.composeEmbeddingText(task: task, summary: snapshot.summary)
            let vector = try await engine.embed(embeddingText)
            guard taskSummaries[id] != nil else { continue }
            let updated = TaskSummaryEntry(
                id: snapshot.id,
                title: snapshot.title,
                summary: snapshot.summary,
                embeddingSourceText: embeddingText,
                embedding: vector,
                embeddingModelID: target,
                status: snapshot.status,
                taskCreatedAt: task.createdAt,
                createdAt: snapshot.createdAt
            )
            taskSummaries[id] = updated
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
