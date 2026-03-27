import Foundation
import NaturalLanguage
import Accelerate

/// Provides sentence-level embeddings using Apple's NaturalLanguage framework
/// and fast cosine similarity via vDSP.
public final class EmbeddingService: Sendable {
    /// The loaded sentence embedding model. Loaded once and reused.
    /// NLEmbedding is thread-safe for read operations (vector lookups) but not marked Sendable.
    private nonisolated(unsafe) let embedding: NLEmbedding

    /// Dimension of the embedding vectors (512 for English sentence embeddings).
    public let dimension: Int

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

    /// Generates a sentence embedding vector for the given text.
    ///
    /// - Parameter text: The text to embed. Works best with single sentences or short paragraphs.
    /// - Returns: A `[Float]` vector of length `dimension`.
    /// - Throws: `EmbeddingError.embeddingFailed` if the model can't produce a vector for this input.
    public func embed(_ text: String) throws -> [Float] {
        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.embeddingFailed(text)
        }
        // NLEmbedding returns [Double]; convert to [Float] for compact storage and vDSP compatibility.
        return vector.map { Float($0) }
    }

    /// Computes cosine similarity between two vectors using vDSP.
    ///
    /// Returns a value in [-1, 1] where 1 means identical direction, 0 means orthogonal,
    /// and -1 means opposite direction.
    ///
    /// - Precondition: Both vectors must have the same length.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vectors must have equal length for cosine similarity")
        let count = vDSP_Length(a.count)

        var dotProduct: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, count)

        var magnitudeA: Float = 0
        vDSP_svesq(a, 1, &magnitudeA, count)
        magnitudeA = sqrt(magnitudeA)

        var magnitudeB: Float = 0
        vDSP_svesq(b, 1, &magnitudeB, count)
        magnitudeB = sqrt(magnitudeB)

        guard magnitudeA > 0, magnitudeB > 0 else { return 0 }
        return dotProduct / (magnitudeA * magnitudeB)
    }
}
