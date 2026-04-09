import Foundation
import NaturalLanguage
import Accelerate
import os

/// Provides sentence-level embeddings using Apple's NaturalLanguage framework
/// and fast dot-product similarity via vDSP (Double precision).
///
/// All vectors are **L2-normalized at insert time**, so cosine similarity reduces
/// to a single dot product at search time — no per-comparison magnitude computation.
///
/// Supports multi-vector (sentence-split) embedding: text is split into individual
/// sentences, each embedded and normalized separately. This aligns with how
/// NLEmbedding was trained and produces better topical matching.
public final class EmbeddingService: Sendable {
    /// The loaded sentence embedding model. Loaded once and reused.
    /// NLEmbedding is thread-safe for read operations (vector lookups) but not marked Sendable.
    private nonisolated(unsafe) let embedding: NLEmbedding

    /// Dimension of the embedding vectors (512 for English sentence embeddings).
    public let dimension: Int

    /// Maximum number of sentence embeddings to store per document.
    private static let maxSentencesPerDocument = 50

    /// Minimum character length for a sentence to be worth embedding.
    private static let minSentenceLength = 10

    /// Process-wide accumulators tracking how often `NLEmbedding.vector(for:)` returns nil.
    /// Useful for spotting drift in embedding quality on real corpora — sentences that fail
    /// to embed are silently skipped, so without this counter the loss is invisible.
    private struct NilStats: Sendable {
        var attempted: Int = 0
        var nilCount: Int = 0
    }
    private let nilStats = OSAllocatedUnfairLock(initialState: NilStats())

    /// Snapshot of cumulative sentence-embedding statistics since this service was created.
    public struct EmbeddingNilStats: Sendable {
        public let attempted: Int
        public let nilCount: Int
        public var nilPercentage: Double {
            attempted == 0 ? 0.0 : Double(nilCount) * 100.0 / Double(attempted)
        }
    }

    /// Returns a snapshot of the cumulative nil-rate counters.
    public func currentNilStats() -> EmbeddingNilStats {
        nilStats.withLock { stats in
            EmbeddingNilStats(attempted: stats.attempted, nilCount: stats.nilCount)
        }
    }

    public enum EmbeddingError: Error, LocalizedError {
        case modelUnavailable(NLLanguage)
        case embeddingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelUnavailable(let language):
                return "Sentence embedding model unavailable for language: \(language.rawValue)"
            case .embeddingFailed(let text):
                let preview = text.prefix(80)
                return "Failed to generate embedding for text: \"\(preview)\""
            }
        }
    }

    /// Creates an embedding service for the given language.
    ///
    /// - Parameter language: The language to load sentence embeddings for. Defaults to `.english`.
    /// - Throws: `EmbeddingError.modelUnavailable` if the model isn't available on this system.
    public init(language: NLLanguage = .english) throws {
        guard let model = NLEmbedding.sentenceEmbedding(for: language) else {
            throw EmbeddingError.modelUnavailable(language)
        }
        self.embedding = model
        self.dimension = model.dimension
    }

    /// Generates a normalized sentence embedding vector for the given text.
    ///
    /// - Parameter text: The text to embed. Works best with single sentences or short paragraphs.
    /// - Returns: An L2-normalized `[Double]` vector of length `dimension`.
    /// - Throws: `EmbeddingError.embeddingFailed` if the model can't produce a vector for this input.
    public func embed(_ text: String) throws -> [Double] {
        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.embeddingFailed(text)
        }
        return Self.l2Normalize(vector)
    }

    /// Splits text into sentences and embeds each one separately.
    ///
    /// Uses `NLTokenizer(unit: .sentence)` for linguistic sentence boundary detection.
    /// Filters out sentences shorter than `minSentenceLength` characters and caps at
    /// `maxSentencesPerDocument`. All vectors are L2-normalized. Tracks nil-vector
    /// returns in process-wide stats so the silent skip rate can be observed.
    ///
    /// - Parameter text: The text to split and embed.
    /// - Returns: An array of normalized embedding vectors, one per sentence.
    /// - Throws: `EmbeddingError.embeddingFailed` if no sentences could be embedded.
    public func splitAndEmbed(_ text: String) throws -> [[Double]] {
        let sentences = Self.splitIntoSentences(text)
        var embeddings: [[Double]] = []
        var localNilCount = 0
        let attemptedSlice = sentences.prefix(Self.maxSentencesPerDocument)
        for sentence in attemptedSlice {
            if let vector = embedding.vector(for: sentence) {
                embeddings.append(Self.l2Normalize(vector))
            } else {
                localNilCount += 1
            }
        }
        let attemptedCount = attemptedSlice.count
        let nilDelta = localNilCount
        if attemptedCount > 0 {
            nilStats.withLock { stats in
                stats.attempted += attemptedCount
                stats.nilCount += nilDelta
            }
        }
        if embeddings.isEmpty {
            // Fall back to embedding the whole text as one vector.
            let vector = try embed(text)
            embeddings.append(vector)
        }
        return embeddings
    }

    /// Splits text into individual sentences using `NLTokenizer(unit: .sentence)`.
    ///
    /// Filters out sentences shorter than `minSentenceLength` characters. NLTokenizer
    /// handles newlines, punctuation, and language-aware boundaries on its own — no
    /// pre-split is needed.
    public static func splitIntoSentences(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= minSentenceLength {
                sentences.append(sentence)
            }
            return true
        }
        return sentences
    }

    // MARK: - Vector Operations

    /// L2-normalizes a vector so its magnitude equals 1.
    ///
    /// After normalization, cosine similarity equals the dot product.
    /// Normalizing once at insert time eliminates per-comparison magnitude computation.
    private static func l2Normalize(_ v: [Double]) -> [Double] {
        let count = vDSP_Length(v.count)
        var norm: Double = 0
        vDSP_svesqD(v, 1, &norm, count)
        guard norm > 0 else { return v }
        var scale = 1.0 / sqrt(norm)
        var result = [Double](repeating: 0, count: v.count)
        vDSP_vsmulD(v, 1, &scale, &result, 1, count)
        return result
    }

    /// Computes the dot product of two normalized vectors (equivalent to cosine similarity).
    ///
    /// Both vectors must be L2-normalized (via `embed` or `splitAndEmbed`).
    /// Returns a value in [-1, 1].
    public static func dotSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count, "Vectors must have equal length")
        var dot: Double = 0
        vDSP_dotprD(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    /// Computes the maximum dot-product similarity between any pair of vectors
    /// from two sets of normalized embeddings.
    ///
    /// This is the core of multi-vector retrieval: if ANY sentence in the query
    /// is similar to ANY sentence in the document, the document scores high.
    public static func maxSimilarity(
        query queryEmbeddings: [[Double]],
        document documentEmbeddings: [[Double]]
    ) -> Double {
        var best: Double = -1
        for q in queryEmbeddings {
            for d in documentEmbeddings {
                let sim = dotSimilarity(q, d)
                if sim > best { best = sim }
            }
        }
        return best
    }
}
