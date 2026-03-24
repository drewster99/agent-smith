import Foundation
import os

private let logger = Logger(subsystem: "SwiftLLMKit", category: "SwiftLLMKit")

/// Central manager for LLM providers, model discovery, and configuration.
///
/// Provides CRUD for providers (with Keychain-stored API keys), model catalog
/// management (provider APIs + LiteLLM metadata enrichment), and configuration
/// management (provider + model + user settings). Also prepares authenticated
/// URLRequests for the app to complete with messages/tools.
///
/// Usage:
/// ```swift
/// let kit = LLMKitManager(
///     appIdentifier: Bundle.main.bundleIdentifier ?? "com.example.app",
///     keychainServicePrefix: "com.example.SwiftLLMKit"
/// )
/// kit.load()
/// await kit.refreshIfNeeded()
/// ```
@Observable
@MainActor
public final class LLMKitManager {
    // MARK: - Published State

    /// All registered providers.
    public private(set) var providers: [ModelProvider] = []
    /// All known models across all providers.
    public private(set) var models: [ModelInfo] = []
    /// All user-defined model configurations.
    public private(set) var configurations: [ModelConfiguration] = []
    /// Whether a model refresh is in progress.
    public private(set) var isRefreshing: Bool = false
    /// Most recent persistence error, if any. Observable so UI can show an alert/banner.
    public var persistenceError: String?

    // MARK: - Services

    private let storage: StorageManager
    private let keychain: KeychainService
    private let fetchService: ModelFetchService
    private let metadataService: ModelMetadataService

    // MARK: - Init

    /// Creates a new SwiftLLMKit instance.
    /// - Parameters:
    ///   - appIdentifier: Typically `Bundle.main.bundleIdentifier`.
    ///   - keychainServicePrefix: Reverse-DNS prefix for Keychain entries.
    public init(
        appIdentifier: String,
        keychainServicePrefix: String
    ) {
        let storage = StorageManager(appIdentifier: appIdentifier)
        self.storage = storage
        self.keychain = KeychainService(
            keychainServicePrefix: keychainServicePrefix,
            appIdentifier: appIdentifier
        )
        self.fetchService = ModelFetchService()
        let suiteName = "SwiftLLMKit.\(appIdentifier)"
        self.metadataService = ModelMetadataService(
            storageDirectory: storage.baseDirectory,
            userDefaultsSuiteName: suiteName
        )
    }

    // MARK: - Persistence

    /// Loads providers, configurations, and cached models from disk.
    public func load() {
        persistenceError = nil
        do {
            providers = try storage.loadProviders()
        } catch {
            let msg = "Failed to load providers: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            persistenceError = msg
        }
        do {
            configurations = try storage.loadConfigurations()
        } catch {
            let msg = "Failed to load configurations: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            persistenceError = msg
        }
        do {
            models = try storage.loadModelCatalog()
        } catch {
            let msg = "Failed to load model catalog: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            persistenceError = msg
        }
    }

    /// Persists current state to disk.
    public func save() {
        var errors: [String] = []
        do {
            try storage.saveProviders(providers)
        } catch {
            let msg = "Failed to save providers: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            errors.append(msg)
        }
        do {
            try storage.saveConfigurations(configurations)
        } catch {
            let msg = "Failed to save configurations: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            errors.append(msg)
        }
        do {
            try storage.saveModelCatalog(models)
        } catch {
            let msg = "Failed to save model catalog: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            errors.append(msg)
        }
        persistenceError = errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    // MARK: - Provider CRUD

    /// Adds a new provider and stores its API key in Keychain.
    ///
    /// - Throws: If the Keychain operation fails. The provider is not persisted on failure.
    public func addProvider(_ provider: ModelProvider, apiKey: String) throws {
        if !apiKey.isEmpty {
            try keychain.save(apiKey: apiKey, forProviderID: provider.id)
        }
        providers.append(provider)
        saveProviders()
    }

    /// Updates an existing provider. If `apiKey` is non-nil, updates the Keychain.
    ///
    /// - Throws: If the Keychain operation fails. The provider is not updated on failure.
    public func updateProvider(_ provider: ModelProvider, apiKey: String?) throws {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        if let apiKey {
            if apiKey.isEmpty {
                try keychain.delete(forProviderID: provider.id)
            } else {
                try keychain.save(apiKey: apiKey, forProviderID: provider.id)
            }
        }
        providers[index] = provider
        saveProviders()
    }

    /// Deletes a provider. Throws if any configuration references it.
    public func deleteProvider(id: String) throws {
        let referencingConfigs = configurations.filter { $0.providerID == id }
        if !referencingConfigs.isEmpty {
            let names = referencingConfigs.map(\.name).joined(separator: ", ")
            throw SwiftLLMKitError.providerInUse(
                providerID: id,
                configNames: names
            )
        }

        providers.removeAll { $0.id == id }
        models.removeAll { $0.providerID == id }

        do {
            try keychain.delete(forProviderID: id)
        } catch {
            logger.error("Failed to delete API key: \(error.localizedDescription, privacy: .public)")
        }

        saveProviders()
        saveModelCatalog()
    }

    /// Retrieves the API key for a provider from Keychain.
    public func apiKey(for providerID: String) -> String? {
        keychain.apiKey(forProviderID: providerID)
    }

    // MARK: - Configuration CRUD

    /// Adds a new model configuration.
    public func addConfiguration(_ config: ModelConfiguration) {
        configurations.append(config)
        validateConfigurations()
    }

    /// Updates an existing model configuration.
    public func updateConfiguration(_ config: ModelConfiguration) {
        guard let index = configurations.firstIndex(where: { $0.id == config.id }) else { return }
        configurations[index] = config
        validateConfigurations()
    }

    /// Deletes a model configuration.
    public func deleteConfiguration(id: UUID) {
        configurations.removeAll { $0.id == id }
        validateConfigurations()
    }

    /// Creates a duplicate of an existing configuration with a new ID and "(Copy)" suffix.
    @discardableResult
    public func duplicateConfiguration(id: UUID) -> ModelConfiguration? {
        guard let original = configurations.first(where: { $0.id == id }) else { return nil }
        let newConfig = ModelConfiguration(
            name: "\(original.name) (Copy)",
            providerID: original.providerID,
            modelID: original.modelID,
            temperature: original.temperature,
            maxOutputTokens: original.maxOutputTokens,
            maxContextTokens: original.maxContextTokens,
            thinkingBudget: original.thinkingBudget,
            streaming: original.streaming
        )
        configurations.append(newConfig)
        validateConfigurations()
        return newConfig
    }

    // MARK: - Model Catalog

    /// Returns models available for a specific provider.
    public func models(for providerID: String) -> [ModelInfo] {
        models.filter { $0.providerID == providerID }
    }

    /// Returns info for a specific model by provider and model ID.
    public func modelInfo(providerID: String, modelID: String) -> ModelInfo? {
        models.first { $0.providerID == providerID && $0.modelID == modelID }
    }

    // MARK: - Refresh

    /// Refreshes model lists if the YYYYMMDD gate allows.
    public func refreshIfNeeded() async {
        let needsMetadataRefresh = await metadataService.needsRefresh()
        if !needsMetadataRefresh && !models.isEmpty {
            // Already loaded and up to date
            return
        }
        await performRefresh()
    }

    /// Always performs a full refresh.
    public func forceRefresh() async {
        await performRefresh()
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // 1. Refresh LiteLLM metadata
        await metadataService.forceRefresh()

        // 2. Fetch models from each provider
        var allModels: [ModelInfo] = []
        for provider in providers {
            let apiKey = keychain.apiKey(forProviderID: provider.id)
            do {
                var providerModels = try await fetchService.fetchModels(
                    from: provider,
                    apiKey: apiKey
                )

                // 3. Enrich with LiteLLM metadata
                for i in providerModels.indices {
                    if let litellm = await metadataService.metadata(for: providerModels[i].modelID, providerType: provider.apiType) {
                        // Provider data is authoritative; LiteLLM fills gaps
                        if providerModels[i].maxInputTokens == nil {
                            providerModels[i].maxInputTokens = litellm.maxInputTokens
                        }
                        if providerModels[i].maxOutputTokens == nil {
                            providerModels[i].maxOutputTokens = litellm.maxOutputTokens
                        }
                        if let cost = litellm.inputCostPerToken {
                            providerModels[i].inputCostPerMillionTokens = cost * 1_000_000
                        }
                        if let cost = litellm.outputCostPerToken {
                            providerModels[i].outputCostPerMillionTokens = cost * 1_000_000
                        }
                        if !litellm.supportsChatCompletions {
                            providerModels[i].supportsChatCompletions = false
                        }
                        litellm.mergeCapabilities(into: &providerModels[i].capabilities)
                    }
                }

                allModels.append(contentsOf: providerModels)
            } catch {
                logger.error("Failed to fetch models from \(provider.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Keep any previously cached models for this provider
                let cached = models.filter { $0.providerID == provider.id }
                allModels.append(contentsOf: cached)
            }
        }

        models = allModels
        saveModelCatalog()

        // 4. Re-validate configurations against the updated catalog
        validateConfigurations()
    }

    // MARK: - Validation

    /// Validates all configurations against current providers and models.
    public func validateConfigurations() {
        for i in configurations.indices {
            validateConfiguration(at: i)
        }
        saveConfigurations()
    }

    private func validateConfiguration(at index: Int) {
        let config = configurations[index]

        // Check provider exists
        guard let provider = providers.first(where: { $0.id == config.providerID }) else {
            configurations[index].isValid = false
            configurations[index].validationError = "Provider '\(config.providerID)' not found"
            return
        }

        // Temperature bounds
        guard (0...2).contains(config.temperature) else {
            configurations[index].isValid = false
            configurations[index].validationError = "Temperature must be between 0 and 2"
            return
        }

        // Thinking budget is Anthropic-only
        if let budget = config.thinkingBudget, budget > 0, provider.apiType != .anthropic {
            configurations[index].isValid = false
            configurations[index].validationError = "Thinking budget is only supported for Anthropic providers"
            return
        }

        // Check model exists in that provider's models
        let providerModels = models.filter { $0.providerID == config.providerID }
        if !providerModels.isEmpty {
            guard let modelInfo = providerModels.first(where: { $0.modelID == config.modelID }) else {
                configurations[index].isValid = false
                configurations[index].validationError = "Model '\(config.modelID)' not found for this provider"
                return
            }

            // Check model supports chat completions
            if !modelInfo.supportsChatCompletions {
                configurations[index].isValid = false
                configurations[index].validationError = "Model '\(config.modelID)' does not support the chat completions endpoint"
                return
            }

            // Check maxOutputTokens doesn't exceed model's reported max
            if let modelMax = modelInfo.maxOutputTokens, config.maxOutputTokens > modelMax {
                configurations[index].isValid = false
                configurations[index].validationError = "Max output tokens (\(config.maxOutputTokens)) exceeds model limit (\(modelMax))"
                return
            }
        } else {
            // Models not yet loaded — allow starting but warn the user
            configurations[index].isValid = true
            configurations[index].validationError = "Models not yet loaded — will re-validate after refresh"
            return
        }

        configurations[index].isValid = true
        configurations[index].validationError = nil
    }

    // MARK: - Request Preparation

    /// Prepares an authenticated URLRequest stub for the given configuration.
    ///
    /// The returned `PreparedRequest` contains the URL, auth headers, and base body
    /// parameters (model, temperature, max_tokens, thinking, stream). The app adds
    /// messages/tools to the body and sends the request.
    public func prepareRequest(for configurationID: UUID) throws -> PreparedRequest {
        guard let config = configurations.first(where: { $0.id == configurationID }) else {
            throw SwiftLLMKitError.configurationNotFound(id: configurationID)
        }
        guard let provider = providers.first(where: { $0.id == config.providerID }) else {
            throw SwiftLLMKitError.providerNotFound(id: config.providerID)
        }

        let apiKey = keychain.apiKey(forProviderID: provider.id)

        // Build URL
        let url: URL
        switch provider.apiType {
        case .anthropic:
            let base = provider.endpoint.path.hasSuffix("/v1")
                ? provider.endpoint
                : provider.endpoint.appendingPathComponent("v1")
            url = base.appendingPathComponent("messages")
        case .openAICompatible, .lmStudio, .mistral, .huggingFace, .xAI:
            url = provider.endpoint.appendingPathComponent("chat/completions")
        case .ollama:
            url = provider.endpoint.appendingPathComponent("chat")
        case .gemini:
            let base = provider.endpoint.appendingPathComponent("models/\(config.modelID):generateContent")
            if let apiKey, !apiKey.isEmpty,
               var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
                var items = components.queryItems ?? []
                items.append(URLQueryItem(name: "key", value: apiKey))
                components.queryItems = items
                url = components.url ?? base
            } else {
                url = base
            }
        }

        // Build URLRequest with headers
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch provider.apiType {
        case .anthropic:
            if let apiKey {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible, .lmStudio, .mistral, .huggingFace, .xAI:
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .ollama:
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .gemini:
            // API key already in URL query parameter
            break
        }

        // Build base body
        var body: [String: Any] = [
            "model": config.modelID,
            "temperature": config.temperature,
            "stream": config.streaming
        ]

        switch provider.apiType {
        case .anthropic:
            body["max_tokens"] = config.maxOutputTokens
            if let budget = config.thinkingBudget, budget > 0 {
                body["thinking"] = ["type": "enabled", "budget_tokens": budget] as [String: Any]
            }
        case .openAICompatible, .lmStudio, .mistral, .huggingFace, .xAI:
            body["max_tokens"] = config.maxOutputTokens
        case .ollama:
            body["options"] = ["num_predict": config.maxOutputTokens] as [String: Any]
        case .gemini:
            body["generationConfig"] = [
                "maxOutputTokens": config.maxOutputTokens,
                "temperature": config.temperature
            ] as [String: Any]
        }

        return PreparedRequest(
            urlRequest: request,
            baseBody: body,
            providerType: provider.apiType,
            streaming: config.streaming
        )
    }

    // MARK: - Private persistence helpers

    private func saveProviders() {
        do {
            try storage.saveProviders(providers)
            persistenceError = nil
        } catch {
            let msg = "Failed to save providers: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            persistenceError = msg
        }
    }

    private func saveConfigurations() {
        do {
            try storage.saveConfigurations(configurations)
            persistenceError = nil
        } catch {
            let msg = "Failed to save configurations: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            persistenceError = msg
        }
    }

    private func saveModelCatalog() {
        do {
            try storage.saveModelCatalog(models)
            persistenceError = nil
        } catch {
            let msg = "Failed to save model catalog: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            persistenceError = msg
        }
    }
}

/// Errors thrown by SwiftLLMKit operations.
public enum SwiftLLMKitError: Error, LocalizedError {
    case providerInUse(providerID: String, configNames: String)
    case configurationNotFound(id: UUID)
    case providerNotFound(id: String)

    public var errorDescription: String? {
        switch self {
        case .providerInUse(_, let names):
            return "Cannot delete provider — it is referenced by configurations: \(names)"
        case .configurationNotFound(let id):
            return "Configuration not found: \(id)"
        case .providerNotFound(let id):
            return "Provider not found: \(id)"
        }
    }
}
