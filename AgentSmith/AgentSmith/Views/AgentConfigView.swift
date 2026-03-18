import SwiftUI
import AgentSmithKit

/// Endpoint/model/key fields for configuring a single agent role's LLM.
struct AgentConfigView: View {
    let roleName: String
    let roleColor: Color
    @Binding var config: LLMConfiguration

    @State private var availableModels: [String] = []
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

                LabeledContent("Provider") {
                    Picker("", selection: $config.providerType) {
                        ForEach(ProviderType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                // Endpoint: editable text field + preset dropdown
                LabeledContent("Endpoint") {
                    HStack(spacing: 4) {
                        TextField("https://…", text: endpointBinding)
                            .textFieldStyle(.roundedBorder)

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
                }

                LabeledContent("API Key") {
                    SecureField("Optional", text: $config.apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Model: text field + fetch button + model picker dropdown
                LabeledContent("Model") {
                    HStack(spacing: 4) {
                        TextField("model name", text: $config.model)
                            .textFieldStyle(.roundedBorder)

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

                        if !availableModels.isEmpty {
                            Menu(
                                content: {
                                    ForEach(availableModels, id: \.self) { model in
                                        Button(model) { config.model = model }
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
                    }
                }

                if let errorMessage = modelFetchError {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                LabeledContent("Temperature") {
                    HStack {
                        Slider(value: $config.temperature, in: 0...2, step: 0.1)
                        Text(String(format: "%.1f", config.temperature))
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                }

                LabeledContent("Max Tokens") {
                    TextField("4096", value: $config.maxTokens, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
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
    ) async throws -> [String] {
        let modelsURL: URL
        switch providerType {
        case .ollama:
            modelsURL = endpoint.appendingPathComponent("tags")
        case .anthropic:
            modelsURL = endpoint.appendingPathComponent("v1/models")
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
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return decoded.models.map(\.name).sorted()
        case .anthropic, .openAICompatible:
            let decoded = try JSONDecoder().decode(ModelsListResponse.self, from: data)
            return decoded.data.map(\.id).sorted()
        }
    }
}

// MARK: - Supporting types (file-private)

private struct ModelsListResponse: Decodable {
    struct ModelEntry: Decodable { let id: String }
    let data: [ModelEntry]
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable { let name: String }
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
