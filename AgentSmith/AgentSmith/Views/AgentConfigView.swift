import SwiftUI
import AgentSmithKit

/// Endpoint/model/key fields for configuring a single agent role's LLM.
struct AgentConfigView: View {
    let roleName: String
    let roleColor: Color
    @Binding var config: LLMConfiguration

    @State private var availableModels: [ModelPickerEntry] = []
    @State private var isLoadingModels = false
    @State private var modelFetchError: String? = nil

    private var endpointBinding: Binding<String> {
        Binding(
            get: { config.endpoint.absoluteString },
            set: { newValue in
                if let url = URL(string: newValue) {
                    config.endpoint = url
                }
            }
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(roleName, systemImage: "person.circle")
                    .font(AppFonts.sectionHeader)
                    .foregroundStyle(roleColor)

                providerRow
                endpointRow
                apiKeyRow
                modelRow

                if let errorMessage = modelFetchError {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                temperatureRow
                maxTokensRow
            }
            .padding(8)
        }
        .onChange(of: config.endpoint) {
            tryFetchModels()
        }
        .onChange(of: config.providerType) {
            tryFetchModels()
        }
        .onChange(of: config.apiKey) {
            tryFetchModels()
        }
    }

    // MARK: - Row sub-views

    private var providerRow: some View {
        LabeledContent("Provider") {
            Picker("", selection: $config.providerType) {
                ForEach(ProviderType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var endpointRow: some View {
        LabeledContent("Endpoint") {
            HStack(spacing: 4) {
                TextField("https://…", text: endpointBinding)
                    .textFieldStyle(.roundedBorder)

                endpointPresetMenu
            }
        }
    }

    private var endpointPresetMenu: some View {
        Menu(
            content: {
                Section("Cloud APIs") {
                    Button("Anthropic") {
                        applyPreset(urlString: "https://api.anthropic.com",
                                    providerType: .anthropic)
                    }
                    Button("OpenAI") {
                        applyPreset(urlString: "https://api.openai.com/v1",
                                    providerType: .openAICompatible)
                    }
                    Button("Ollama (cloud)") {
                        applyPreset(urlString: "https://ollama.com/api",
                                    providerType: .ollama)
                    }
                }
                Section("Local") {
                    Button("Ollama (local)") {
                        applyPreset(urlString: "http://localhost:11434/api",
                                    providerType: .ollama)
                    }
                    Button("LM Studio") {
                        applyPreset(urlString: "http://localhost:1234/v1",
                                    providerType: .openAICompatible)
                    }
                }
            },
            label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
            }
        )
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help("Choose a common endpoint")
    }

    private var apiKeyRow: some View {
        LabeledContent("API Key") {
            SecureField("Optional", text: $config.apiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// The fetched entry matching the currently selected model, if any.
    private var selectedModelEntry: ModelPickerEntry? {
        availableModels.first { $0.modelName == config.model }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Model") {
                HStack(spacing: 4) {
                    TextField("model name", text: $config.model)
                        .textFieldStyle(.roundedBorder)

                    fetchButton

                    if !availableModels.isEmpty {
                        modelPickerMenu
                    }
                }
            }

            if let entry = selectedModelEntry {
                modelInfoBar(for: entry)
            }
        }
    }

    /// Compact info bar showing known metadata for the selected model.
    private func modelInfoBar(for entry: ModelPickerEntry) -> some View {
        HStack(spacing: 12) {
            if let maxOut = entry.maxOutputTokens {
                let exceeds = config.maxTokens > maxOut
                HStack(spacing: 2) {
                    Text("Max output:")
                        .foregroundStyle(.secondary)
                    Text(formatTokenCount(maxOut))
                        .foregroundStyle(exceeds ? .red : .primary)
                }
            }
            if let maxIn = entry.maxInputTokens {
                HStack(spacing: 2) {
                    Text("Context:")
                        .foregroundStyle(.secondary)
                    Text(formatTokenCount(maxIn))
                }
            }
            if let caps = entry.capabilities, !caps.isEmpty {
                HStack(spacing: 2) {
                    ForEach(caps, id: \.self) { cap in
                        Text(cap)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
        }
        .font(.caption)
    }

    private var fetchButton: some View {
        Button(
            action: {
                Task {
                    do {
                        try await performFetchModels()
                    } catch {
                        modelFetchError = error.localizedDescription
                        isLoadingModels = false
                    }
                }
            },
            label: {
                if isLoadingModels {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
            }
        )
        .buttonStyle(.borderless)
        .frame(width: 24)
        .disabled(isLoadingModels)
        .help("Fetch available models from this endpoint")
    }

    private var modelPickerMenu: some View {
        Menu(
            content: {
                ForEach(availableModels) { entry in
                    Button(action: { config.model = entry.modelName }) {
                        HStack {
                            Text(entry.menuLabel)
                            if entry.isNew {
                                Spacer()
                                Text("New")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            },
            label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
            }
        )
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help("Select from fetched models")
    }

    private var temperatureRow: some View {
        LabeledContent("Temperature") {
            HStack {
                Slider(value: $config.temperature, in: 0...2, step: 0.1)
                Text(String(format: "%.1f", config.temperature))
                    .monospacedDigit()
                    .frame(width: 30)
            }
        }
    }

    private var maxTokensRow: some View {
        LabeledContent("Max Tokens") {
            TextField("4096", value: $config.maxTokens, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
        }
    }

    // MARK: - Private

    private func applyPreset(urlString: String, providerType: ProviderType) {
        guard let url = URL(string: urlString) else { return }
        config.endpoint = url
        config.providerType = providerType
        clearFetchedModels()
    }

    private func clearFetchedModels() {
        availableModels = []
        modelFetchError = nil
    }

    private func tryFetchModels() {
        Task {
            do {
                try await performFetchModels()
            } catch {
                modelFetchError = error.localizedDescription
                isLoadingModels = false
            }
        }
    }

    private func performFetchModels() async throws {
        isLoadingModels = true
        modelFetchError = nil
        defer { isLoadingModels = false }
        availableModels = try await queryModels(
            endpoint: config.endpoint,
            apiKey: config.apiKey,
            providerType: config.providerType
        )
    }

    private func queryModels(
        endpoint: URL,
        apiKey: String,
        providerType: ProviderType
    ) async throws -> [ModelPickerEntry] {
        let modelsURL: URL
        switch providerType {
        case .ollama:
            modelsURL = endpoint.appendingPathComponent("tags")
        case .anthropic:
            // Strip a trailing /v1 segment so users who enter the base URL either way
            // (https://api.anthropic.com or https://api.anthropic.com/v1) both work.
            let base = endpoint.path.hasSuffix("/v1")
                ? endpoint.deletingLastPathComponent()
                : endpoint
            modelsURL = base.appendingPathComponent("v1/models")
        case .openAICompatible:
            modelsURL = endpoint.appendingPathComponent("models")
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        switch providerType {
        case .ollama:
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModelFetchError.httpError(statusCode: code)
        }

        switch providerType {
        case .ollama:
            return try decodeOllamaModels(from: data)
        case .anthropic:
            return try decodeAnthropicModels(from: data)
        case .openAICompatible:
            return try decodeOpenAIModels(from: data)
        }
    }

    private func decodeOllamaModels(from data: Data) throws -> [ModelPickerEntry] {
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models
            .map { model in
                let quant = model.details?.quantizationLevel ?? ""
                return ModelPickerEntry(
                    modelName: model.name,
                    sizeLabel: formatBytes(model.size),
                    quantLabel: quant.isEmpty ? "" : quant,
                    rawDate: parseISODate(model.modifiedAt),
                    capabilities: model.capabilities
                )
            }
            .sorted { $0.modelName < $1.modelName }
    }

    private func decodeAnthropicModels(from data: Data) throws -> [ModelPickerEntry] {
        let decoded = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
        return decoded.data
            .map { model in
                ModelPickerEntry(
                    modelName: model.id,
                    displayName: model.displayName ?? "",
                    rawDate: model.createdAt.flatMap { parseISODate($0) },
                    maxOutputTokens: model.maxTokens,
                    maxInputTokens: model.maxInputTokens
                )
            }
            .sorted { $0.modelName < $1.modelName }
    }

    private func decodeOpenAIModels(from data: Data) throws -> [ModelPickerEntry] {
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data
            .map { model in
                ModelPickerEntry(
                    modelName: model.id,
                    ownerLabel: model.ownedBy ?? "",
                    rawDate: model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
            .sorted { $0.modelName < $1.modelName }
    }

    /// Converts a byte count to a compact parameter-style label: M / B / T.
    /// Values < 10 show one decimal place; ≥ 10 show none. Returns "" for zero.
    private func formatBytes(_ bytes: Int64) -> String {
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

    /// Formats a token count as a compact "16K" / "1M" label.
    private func formatTokenCount(_ count: Int) -> String {
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

    /// Parses an ISO 8601 date string into a `Date`.
    private func parseISODate(_ iso: String) -> Date? {
        let parser = ISO8601DateFormatter()
        return parser.date(from: iso)
    }
}

// MARK: - Supporting types (file-private)

/// A model entry in the picker, with display metadata.
private struct ModelPickerEntry: Identifiable {
    var id: String { modelName }
    /// The model identifier sent to the API.
    let modelName: String
    /// Human-readable name (Anthropic provides this; others fall back to modelName).
    let displayName: String
    /// Compact size label, e.g. "8.6B" (Ollama only).
    let sizeLabel: String
    /// Quantization level, e.g. "Q4_K_M" (Ollama only).
    let quantLabel: String
    /// Owner/organization label, e.g. "openai" (OpenAI only).
    let ownerLabel: String
    /// Raw creation or last-modified date, used for "New" badge computation.
    let rawDate: Date?
    /// Maximum output tokens the model supports (Anthropic).
    let maxOutputTokens: Int?
    /// Maximum input context window tokens (Anthropic).
    let maxInputTokens: Int?
    /// Capability tags reported by the provider, e.g. ["completion", "tools"] (Ollama).
    let capabilities: [String]?

    init(
        modelName: String,
        displayName: String = "",
        sizeLabel: String = "",
        quantLabel: String = "",
        ownerLabel: String = "",
        rawDate: Date? = nil,
        maxOutputTokens: Int? = nil,
        maxInputTokens: Int? = nil,
        capabilities: [String]? = nil
    ) {
        self.modelName = modelName
        self.displayName = displayName.isEmpty ? modelName : displayName
        self.sizeLabel = sizeLabel
        self.quantLabel = quantLabel
        self.ownerLabel = ownerLabel
        self.rawDate = rawDate
        self.maxOutputTokens = maxOutputTokens
        self.maxInputTokens = maxInputTokens
        self.capabilities = capabilities
    }

    /// Whether the model was created/modified within the last 90 days.
    var isNew: Bool {
        guard let rawDate else { return false }
        return rawDate > Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date.distantPast
    }

    /// Single-line label used in the picker menu.
    var menuLabel: String {
        var parts: [String] = []
        // Use displayName if it differs from modelName (e.g. Anthropic's "Claude Opus 4.6")
        let primary = displayName == modelName ? modelName : "\(displayName)  (\(modelName))"
        var meta: [String] = []
        if !sizeLabel.isEmpty  { meta.append(sizeLabel) }
        if !quantLabel.isEmpty { meta.append(quantLabel) }
        if !ownerLabel.isEmpty { meta.append(ownerLabel) }
        parts.append(primary)
        if !meta.isEmpty { parts.append(meta.joined(separator: " · ")) }
        return parts.joined(separator: "   ")
    }
}

// MARK: - API response types

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
        /// Capability tags, e.g. ["completion", "tools"]. Present in newer Ollama versions.
        let capabilities: [String]?
        enum CodingKeys: String, CodingKey {
            case name, size, capabilities
            case modifiedAt = "modified_at"
            case details
        }
    }
    let models: [Model]
}

private enum ModelFetchError: LocalizedError {
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "Server returned HTTP \(code). Check the endpoint URL and API key."
        }
    }
}
