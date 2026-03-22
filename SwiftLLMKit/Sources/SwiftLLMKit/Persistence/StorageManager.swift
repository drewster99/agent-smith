import Foundation
import os

private let logger = Logger(subsystem: "SwiftLLMKit", category: "Storage")

/// Manages file-based persistence for SwiftLLMKit data.
///
/// Storage layout:
/// ```
/// <ApplicationSupport>/SwiftLLMKit/<appBundleID>/
///     providers.json
///     model_configurations.json
///     model_catalog.json           (cached, rebuilt on refresh)
///     litellm_metadata.json        (cached from GitHub)
///     litellm_headers.json         (ETag/Last-Modified for conditional fetch)
/// ```
struct StorageManager: Sendable {
    let baseDirectory: URL

    /// Creates a storage manager for the given app identifier.
    /// - Parameter appIdentifier: Typically `Bundle.main.bundleIdentifier`.
    init(appIdentifier: String) {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure("Application Support directory unavailable")
        }
        self.baseDirectory = appSupport
            .appendingPathComponent("SwiftLLMKit", isDirectory: true)
            .appendingPathComponent(appIdentifier, isDirectory: true)
    }

    /// Ensures the storage directory exists.
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Providers

    func saveProviders(_ providers: [ModelProvider]) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(providers)
        try data.write(to: providersURL, options: .atomic)
    }

    func loadProviders() throws -> [ModelProvider] {
        guard FileManager.default.fileExists(atPath: providersURL.path) else { return [] }
        let data = try Data(contentsOf: providersURL)
        return try JSONDecoder().decode([ModelProvider].self, from: data)
    }

    // MARK: - Model Configurations

    func saveConfigurations(_ configurations: [ModelConfiguration]) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configurations)
        try data.write(to: configurationsURL, options: .atomic)
    }

    func loadConfigurations() throws -> [ModelConfiguration] {
        guard FileManager.default.fileExists(atPath: configurationsURL.path) else { return [] }
        let data = try Data(contentsOf: configurationsURL)
        return try JSONDecoder().decode([ModelConfiguration].self, from: data)
    }

    // MARK: - Model Catalog (cache)

    func saveModelCatalog(_ models: [ModelInfo]) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(models)
        try data.write(to: modelCatalogURL, options: .atomic)
    }

    func loadModelCatalog() throws -> [ModelInfo] {
        guard FileManager.default.fileExists(atPath: modelCatalogURL.path) else { return [] }
        let data = try Data(contentsOf: modelCatalogURL)
        return try JSONDecoder().decode([ModelInfo].self, from: data)
    }

    // MARK: - URLs

    private var providersURL: URL {
        baseDirectory.appendingPathComponent("providers.json")
    }

    private var configurationsURL: URL {
        baseDirectory.appendingPathComponent("model_configurations.json")
    }

    private var modelCatalogURL: URL {
        baseDirectory.appendingPathComponent("model_catalog.json")
    }
}
