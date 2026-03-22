import Foundation
import os

private let logger = Logger(subsystem: "SwiftLLMKit", category: "ModelFetch")

/// Queries provider APIs for available model lists.
public struct ModelFetchService: Sendable {
    /// When true, full request/response JSON is logged to `$TMPDIR/SwiftLLMKit-Logs/`.
    public nonisolated(unsafe) static var verboseLogging = false

    public init() {}

    /// Fetches available models from a provider endpoint.
    /// - Parameters:
    ///   - provider: The provider to query.
    ///   - apiKey: The API key for authentication (from Keychain).
    /// - Returns: Array of `ModelInfo` with `providerID` populated.
    public func fetchModels(
        from provider: ModelProvider,
        apiKey: String?
    ) async throws -> [ModelInfo] {
        let modelsURL: URL
        switch provider.apiType {
        case .ollama:
            modelsURL = provider.endpoint.appendingPathComponent("tags")
        case .anthropic:
            let base = provider.endpoint.path.hasSuffix("/v1")
                ? provider.endpoint.deletingLastPathComponent()
                : provider.endpoint
            modelsURL = base.appendingPathComponent("v1/models")
        case .openAICompatible:
            modelsURL = provider.endpoint.appendingPathComponent("models")
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        switch provider.apiType {
        case .ollama:
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            if let apiKey {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        logger.debug("Model fetch: GET \(modelsURL.absoluteString, privacy: .public)")
        if Self.verboseLogging {
            Self.log("REQUEST GET \(modelsURL.absoluteString) provider=\(provider.name)")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
            logger.error("Model fetch failed: HTTP \(code, privacy: .public) body=\(body, privacy: .private)")
            if Self.verboseLogging {
                Self.logData(label: "ModelFetch_error", data: data)
            }
            throw ModelFetchError.httpError(statusCode: code)
        }

        if Self.verboseLogging {
            Self.logData(label: "ModelFetch_\(provider.name)", data: data)
        }

        switch provider.apiType {
        case .ollama:
            return try decodeOllamaModels(from: data, providerID: provider.id)
        case .anthropic:
            return try decodeAnthropicModels(from: data, providerID: provider.id)
        case .openAICompatible:
            return try decodeOpenAIModels(from: data, providerID: provider.id)
        }
    }

    // MARK: - Ollama

    private func decodeOllamaModels(from data: Data, providerID: String) throws -> [ModelInfo] {
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models
            .map { model in
                let quant = model.details?.quantizationLevel ?? ""
                var caps = ModelCapabilities()
                if let capabilities = model.capabilities {
                    caps.toolUse = capabilities.contains("tools")
                }
                return ModelInfo(
                    providerID: providerID,
                    modelID: model.name,
                    createdAt: parseISODate(model.modifiedAt),
                    capabilities: caps,
                    sizeLabel: formatBytes(model.size),
                    quantizationLabel: quant.isEmpty ? nil : quant
                )
            }
            .sorted { $0.modelID < $1.modelID }
    }

    // MARK: - Anthropic

    private func decodeAnthropicModels(from data: Data, providerID: String) throws -> [ModelInfo] {
        let decoded = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
        return decoded.data
            .map { model in
                ModelInfo(
                    providerID: providerID,
                    modelID: model.id,
                    displayName: model.displayName ?? model.id,
                    createdAt: model.createdAt.flatMap { parseISODate($0) },
                    maxInputTokens: model.maxInputTokens,
                    maxOutputTokens: model.maxTokens
                )
            }
            .sorted { $0.modelID < $1.modelID }
    }

    // MARK: - OpenAI Compatible

    private func decodeOpenAIModels(from data: Data, providerID: String) throws -> [ModelInfo] {
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data
            .map { model in
                ModelInfo(
                    providerID: providerID,
                    modelID: model.id,
                    createdAt: model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
            .sorted { $0.modelID < $1.modelID }
    }

    // MARK: - Helpers

    /// Converts a byte count to a compact parameter-style label: M / B / T.
    func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let d = Double(bytes)
        let trillion: Double = 1_000_000_000_000
        let billion: Double  = 1_000_000_000
        let million: Double  = 1_000_000
        let value: Double
        let suffix: String
        if d >= trillion      { value = d / trillion; suffix = "T" }
        else if d >= billion  { value = d / billion;  suffix = "B" }
        else                  { value = d / million;  suffix = "M" }
        return value < 10
            ? String(format: "%.1f\(suffix)", value)
            : String(format: "%.0f\(suffix)", value)
    }

    /// Parses an ISO 8601 date string into a `Date`.
    /// Handles nanosecond-precision timestamps (e.g. from Ollama) by truncating to milliseconds.
    func parseISODate(_ iso: String) -> Date? {
        let truncated = iso.replacingOccurrences(
            of: #"(\.\d{3})\d+"#,
            with: "$1",
            options: .regularExpression
        )
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: truncated) {
            return date
        }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: iso)
    }

    // MARK: - Verbose logging helpers

    private static let logDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftLLMKit-Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func log(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        print("[ModelFetch] \(f.string(from: Date())) \(message)")
    }

    static func logData(label: String, data: Data) {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss.SSS"
        let stamp = f.string(from: Date())
        let safeLabel = label.replacingOccurrences(of: " ", with: "_")
        let file = logDirectory.appendingPathComponent("\(stamp)_\(safeLabel)_response.json")
        if let parsed = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            try? prettyString.write(to: file, atomically: true, encoding: .utf8)
        } else {
            try? data.write(to: file)
        }
        print("[ModelFetch] \(stamp) Response logged to \(file.path)")
    }
}

/// Formats a token count as a compact "16K" / "1M" label.
public func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        let value = Double(count) / 1_000_000
        return value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fM", value)
            : String(format: "%.1fM", value)
    } else if count >= 1_000 {
        let value = Double(count) / 1_000
        return value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fK", value)
            : String(format: "%.1fK", value)
    }
    return "\(count)"
}

/// Formats a per-million-token cost as a compact dollar string, e.g. "$3.00", "$0.28".
public func formatCostPerMillion(_ cost: Double) -> String {
    if cost < 0.01 {
        return String(format: "$%.4f", cost)
    } else if cost < 1 {
        return String(format: "$%.2f", cost)
    } else {
        return String(format: "$%.2f", cost)
    }
}

// MARK: - Errors

/// Errors from model list fetching.
public enum ModelFetchError: Error, LocalizedError {
    case httpError(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "Server returned HTTP \(code). Check the endpoint URL and API key."
        }
    }
}

// MARK: - API Response Types

private struct AnthropicModelsResponse: Decodable {
    struct ModelEntry: Decodable {
        let id: String
        let displayName: String?
        let createdAt: String?
        let maxTokens: Int?
        let maxInputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case createdAt = "created_at"
            case maxTokens = "max_tokens"
            case maxInputTokens = "max_input_tokens"
        }
    }
    let data: [ModelEntry]
}

private struct OpenAIModelsResponse: Decodable {
    struct ModelEntry: Decodable {
        let id: String
        let created: Int?
        let ownedBy: String?
        enum CodingKeys: String, CodingKey {
            case id, created
            case ownedBy = "owned_by"
        }
    }
    let data: [ModelEntry]
}

private struct OllamaTagsResponse: Decodable {
    struct Details: Decodable {
        let quantizationLevel: String?
        enum CodingKeys: String, CodingKey {
            case quantizationLevel = "quantization_level"
        }
    }
    struct Model: Decodable {
        let name: String
        let size: Int64
        let modifiedAt: String
        let details: Details?
        let capabilities: [String]?
        enum CodingKeys: String, CodingKey {
            case name, size, capabilities
            case modifiedAt = "modified_at"
            case details
        }
    }
    let models: [Model]
}
