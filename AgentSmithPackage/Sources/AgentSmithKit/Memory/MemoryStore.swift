import Foundation

/// Search result pairing a memory with its scoring breakdown.
///
/// `similarity` is the raw cosine similarity from the sentence embeddings (kept under
/// the historical name so existing display code that formats it as a percentage stays
/// meaningful). `textScore` and `rrfScore` are additive: callers can ignore them, but
/// the search ordering returned by `MemoryStore` is by `rrfScore` descending.
public struct MemorySearchResult: Sendable {
    public let memory: MemoryEntry
    /// Raw semantic similarity (max sentence-pair cosine), in [-1, 1] but typically [0, 1].
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

    /// Updates an existing memory's content and/or tags. Records who performed the edit
    /// in the entry's `lastUpdatedAt` / `lastUpdatedBy` fields. Re-embeds when the content
    /// changed. Returns the updated entry, or nil if the ID wasn't found.
    @discardableResult
    public func update(
        id: UUID,
        content: String? = nil,
        tags: [String]? = nil,
        updatedBy: MemoryEntry.UpdateSource
    ) throws -> MemoryEntry? {
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

    /// Saves a task summary, splitting the rich composite text into sentences
    /// and embedding each one for multi-vector search. Captures the task's original
    /// `createdAt` so the editor can show "when the task was asked for" rather than
    /// "when the summary was generated."
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
    /// considered. Replaces the historical tier1/tier2 thresholds.
    private static let searchAllNoiseFloor: Double = 0.55

    /// Common English stopwords stripped from query tokens before text scoring.
    /// Stopwords are too noisy to drive keyword matching — they appear in nearly every
    /// document and would inflate text scores without indicating real relevance.
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

    /// Lowercases and tokenizes a string into alphanumeric runs of length ≥ 2.
    /// Non-letters/digits act as delimiters; tokens shorter than 2 chars are dropped
    /// to filter out incidental noise (single letters, punctuation residue).
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

    /// Builds the de-duplicated, stopword-filtered token set for a query.
    /// Returned set is empty when the query has no meaningful keywords (all stopwords or
    /// pure punctuation), in which case `textScore` will return 0 for all documents.
    private static func queryTokenSet(from query: String) -> Set<String> {
        Set(tokenize(query).filter { !englishStopwords.contains($0) })
    }

    /// Computes the text-overlap score for a document against a pre-computed query token set.
    ///
    /// Score = (number of distinct query tokens that appear as whole tokens in the document) /
    ///         (total distinct query tokens). Range: [0, 1].
    ///
    /// Whole-token matching (rather than substring) avoids false positives like "se" in
    /// "selenium". Document tokens are computed once per call.
    private static func textScore(queryTokens: Set<String>, document: String) -> Double {
        guard !queryTokens.isEmpty else { return 0.0 }
        let documentTokens = Set(tokenize(document))
        let matched = queryTokens.intersection(documentTokens)
        return Double(matched.count) / Double(queryTokens.count)
    }

    /// Computes Reciprocal Rank Fusion scores for a set of candidates that have already
    /// been scored on two independent signals (semantic and text). Returns the RRF score
    /// for each candidate index, in the original input order.
    ///
    /// RRF formula: `1 / (k + rank)` summed across both rankings, with `k = rrfK = 60`.
    /// Ranks are 1-indexed and assigned by sorting each signal independently. Ties on a
    /// signal share the lower rank (so 3-way tie at the top all get rank 1).
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

    /// Assigns 1-indexed ranks based on score (higher score = better rank). Ties share
    /// the lower rank — three documents tied at the top all get rank 1, the next gets
    /// rank 4. This avoids penalizing ties under RRF.
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

    // MARK: - Search

    /// Searches memories using Reciprocal Rank Fusion of semantic similarity and keyword
    /// overlap. The `threshold` parameter is a noise floor on `MAX(semantic, text)` — a
    /// candidate must score at least this much on EITHER signal to be considered.
    /// Updates `lastAccessedAt` on returned results.
    public func searchMemories(
        query: String,
        limit: Int = 5,
        threshold: Double = 0.10
    ) throws -> [MemorySearchResult] {
        let start = Date()
        let queryEmbeddings = try embeddingService.splitAndEmbed(query)
        let queryTokens = Self.queryTokenSet(from: query)
        let results = searchMemories(
            queryEmbeddings: queryEmbeddings,
            queryTokens: queryTokens,
            limit: limit,
            threshold: threshold
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[MemoryStore] searchMemories: \(results.count) results from \(memories.count) memories in \(ms)ms (query: \(query.prefix(60))) [\(Self.formattedNilStats(embeddingService))]")
        return results
    }

    /// Searches memories using pre-computed query sentence embeddings and query tokens.
    ///
    /// Pipeline:
    /// 1. Compute semantic + text scores for every memory.
    /// 2. Filter by `MAX(semantic, text) >= threshold` so a strong signal in either
    ///    channel is enough to keep a candidate (matches the intent of having both
    ///    a semantic and a lexical retrieval channel).
    /// 3. Rank survivors by semantic score and by text score independently.
    /// 4. Compute RRF (k=60) per survivor.
    /// 5. Sort by RRF descending, return the top `limit`.
    ///
    /// `similarity` on the result is the raw semantic score (for display continuity).
    /// `rrfScore` is the value used to determine the order returned here.
    private func searchMemories(
        queryEmbeddings: [[Double]],
        queryTokens: Set<String>,
        limit: Int,
        threshold: Double
    ) -> [MemorySearchResult] {
        // Step 1: score every memory.
        var entryRefs: [MemoryEntry] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []
        for entry in memories.values {
            let semantic = EmbeddingService.maxSimilarity(
                query: queryEmbeddings, document: entry.embeddings
            )
            let text = Self.textScore(queryTokens: queryTokens, document: entry.content)
            // Step 2: noise filter — either signal can keep a candidate alive.
            if max(semantic, text) >= threshold {
                entryRefs.append(entry)
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }

        guard !entryRefs.isEmpty else { return [] }

        // Steps 3 & 4: ranks and RRF, computed across the surviving candidate set.
        let rrfScores = Self.reciprocalRankFusion(
            semanticScores: semanticScores,
            textScores: textScores
        )

        // Build results then sort by RRF descending.
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

        let topResults = Array(results.prefix(limit))

        // NOTE: Retrieval tracking (lastRetrievedAt + retrievalCount) is intentionally
        // NOT updated here. This private method is the underlying primitive used by both
        // editor browsing and agent-driven searches; we only count "real" retrievals,
        // which `searchAll` records explicitly on the items it returns.

        return topResults
    }

    /// Searches task summaries using Reciprocal Rank Fusion of semantic similarity and
    /// keyword overlap. See `searchMemories(query:limit:threshold:)` for the threshold
    /// semantics.
    public func searchTaskSummaries(
        query: String,
        limit: Int = 5,
        threshold: Double = 0.10
    ) throws -> [TaskSummarySearchResult] {
        let start = Date()
        let queryEmbeddings = try embeddingService.splitAndEmbed(query)
        let queryTokens = Self.queryTokenSet(from: query)
        let results = searchTaskSummaries(
            queryEmbeddings: queryEmbeddings,
            queryTokens: queryTokens,
            limit: limit,
            threshold: threshold
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[MemoryStore] searchTaskSummaries: \(results.count) results from \(taskSummaries.count) summaries in \(ms)ms (query: \(query.prefix(60))) [\(Self.formattedNilStats(embeddingService))]")
        return results
    }

    /// Searches task summaries using pre-computed query sentence embeddings and query tokens.
    /// Text matching is performed against `embeddingSourceText`, which is the same composite
    /// text (title + description + summary + result + commentary + updates) that produced
    /// the embeddings — keeping the two scoring channels symmetric.
    private func searchTaskSummaries(
        queryEmbeddings: [[Double]],
        queryTokens: Set<String>,
        limit: Int,
        threshold: Double
    ) -> [TaskSummarySearchResult] {
        var entryRefs: [TaskSummaryEntry] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []
        for entry in taskSummaries.values {
            let semantic = EmbeddingService.maxSimilarity(
                query: queryEmbeddings, document: entry.embeddings
            )
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
    ///
    /// 1. Pool every memory and every task summary into a single candidate set, scoring
    ///    each on semantic similarity AND keyword overlap.
    /// 2. Drop pure-noise candidates whose better signal is below `searchAllNoiseFloor`.
    /// 3. Compute joint semantic and lexical ranks across the pooled survivors.
    /// 4. Compute RRF (k=60) per survivor.
    /// 5. Return the top 4 by RRF, bucketed back into memories vs task summaries.
    ///
    /// `memoryLimit` and `taskLimit` are kept as caller-facing knobs but the function
    /// caps the joint result at 4 (3+3 minus overlap). The blended `similarity` field
    /// on each result is the raw semantic score (for display continuity).
    public func searchAll(
        query: String,
        memoryLimit: Int = 3,
        taskLimit: Int = 3
    ) throws -> SemanticSearchResults {
        let start = Date()
        let queryEmbeddings = try embeddingService.splitAndEmbed(query)
        let queryTokens = Self.queryTokenSet(from: query)

        // Step 1: pool all candidates with both signal scores.
        enum CandidateRef {
            case memory(MemoryEntry)
            case task(TaskSummaryEntry)
        }
        var refs: [CandidateRef] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []

        for entry in memories.values {
            let semantic = EmbeddingService.maxSimilarity(
                query: queryEmbeddings, document: entry.embeddings
            )
            let text = Self.textScore(queryTokens: queryTokens, document: entry.content)
            // Step 2: noise floor (either signal can keep a candidate alive).
            if max(semantic, text) >= Self.searchAllNoiseFloor {
                refs.append(.memory(entry))
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }
        for entry in taskSummaries.values {
            let semantic = EmbeddingService.maxSimilarity(
                query: queryEmbeddings, document: entry.embeddings
            )
            let text = Self.textScore(queryTokens: queryTokens, document: entry.embeddingSourceText)
            if max(semantic, text) >= Self.searchAllNoiseFloor {
                refs.append(.task(entry))
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }

        guard !refs.isEmpty else {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("[MemoryStore] searchAll: 0 results in \(ms)ms (query: \(query.prefix(60))) [\(Self.formattedNilStats(embeddingService))]")
            return SemanticSearchResults(memories: [], taskSummaries: [])
        }

        // Steps 3 & 4: joint ranks across the pooled set + RRF.
        let rrfScores = Self.reciprocalRankFusion(
            semanticScores: semanticScores,
            textScores: textScores
        )

        // Pair indices with RRF and sort.
        let order = (0..<refs.count).sorted { rrfScores[$0] > rrfScores[$1] }

        // Step 5: bucket the top 4 back into typed results, preserving the joint order.
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
                // Record the retrieval — this is an agent-driven search returning a memory
                // for actual use, so it counts toward `lastRetrievedAt` and `retrievalCount`.
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

        // Persist the retrieval-counter changes via the standard onChange path so they
        // survive a Smith restart. Only fired if at least one memory was actually
        // retrieved this call — task-only result sets don't dirty the store.
        if trackedAnyRetrieval { onChange?() }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[MemoryStore] searchAll: \(memoryResults.count) memories + \(taskResults.count) tasks in \(ms)ms (query: \(query.prefix(60))) [\(Self.formattedNilStats(embeddingService))]")
        return SemanticSearchResults(memories: memoryResults, taskSummaries: taskResults)
    }

    /// Compact "x/y nil (z%)" string for log lines, reading from the embedding service.
    private static func formattedNilStats(_ service: EmbeddingService) -> String {
        let stats = service.currentNilStats()
        return String(format: "embed nils: %d/%d (%.1f%%)", stats.nilCount, stats.attempted, stats.nilPercentage)
    }

    // MARK: - Re-embedding

    /// Re-generates embedding vectors for all memories using multi-sentence splitting.
    ///
    /// Each memory's content is split into individual sentences via `NLTokenizer`,
    /// and each sentence is embedded and L2-normalized separately. This replaces
    /// any previously stored embeddings (including legacy single-vector Float embeddings).
    ///
    /// Use cases:
    /// - Migration from single-vector to multi-vector embeddings
    /// - Migration from Float to Double precision
    /// - Recovering from a corrupted embedding state
    /// - Re-embedding after the underlying NLEmbedding model changes
    ///
    /// This is an O(n * s) operation where n = memory count and s = avg sentences per memory.
    /// Triggers a single `onChange` notification after all memories are processed.
    ///
    /// - Returns: The number of memories re-embedded.
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
                lastRetrievedAt: entry.lastRetrievedAt,
                retrievalCount: entry.retrievalCount,
                lastUpdatedAt: entry.lastUpdatedAt,
                lastUpdatedBy: entry.lastUpdatedBy
            )
            count += 1
        }
        if count > 0 { onChange?() }
        return count
    }

    /// Re-generates embedding vectors for task summaries using full task data.
    ///
    /// For each task that has an existing summary, builds a rich composite text from
    /// all available fields (title, description, summary, result, commentary, updates),
    /// then splits into individual sentences and embeds each one separately.
    /// Also updates the `embeddingSourceText` field on each entry.
    ///
    /// Use cases:
    /// - Migration from summary-only embeddings to full-task-data embeddings
    /// - Migration from single-vector to multi-vector embeddings
    /// - Re-embedding after task data has been modified externally
    ///
    /// Only processes tasks that have a matching entry in the task summary store.
    /// Triggers a single `onChange` notification after all summaries are processed.
    ///
    /// - Parameter tasks: The full `AgentTask` objects to extract embedding text from.
    /// - Returns: The number of task summaries re-embedded.
    @discardableResult
    public func reembedTaskSummariesFromTasks(_ tasks: [AgentTask]) throws -> Int {
        var count = 0
        for task in tasks {
            guard let existing = taskSummaries[task.id] else { continue }
            let embeddingText = Self.composeEmbeddingText(task: task, summary: existing.summary)
            let newEmbeddings = try embeddingService.splitAndEmbed(embeddingText)
            // Backfill `taskCreatedAt` from the live task on each reembed pass — legacy
            // entries that lacked the field will pick up the real task creation date here.
            taskSummaries[task.id] = TaskSummaryEntry(
                id: existing.id,
                title: existing.title,
                summary: existing.summary,
                embeddingSourceText: embeddingText,
                embeddings: newEmbeddings,
                status: existing.status,
                taskCreatedAt: task.createdAt,
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
