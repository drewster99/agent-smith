import SwiftUI
import SwiftLLMKit

/// Sheet for creating or editing a `ModelConfiguration`.
struct ModelConfigurationEditorView: View {
    let llmKit: LLMKitManager
    let existingConfig: ModelConfiguration?
    let onSave: (ModelConfiguration) -> Void
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var selectedProviderID: String = ""
    @State private var selectedModelID: String = ""
    @State private var temperature: Double = 0.7
    @State private var maxOutputTokens: Int = 4096
    @State private var maxContextTokens: Int = 128_000
    @State private var thinkingBudget: Int = 0
    @State private var streaming: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingConfig == nil ? "New Configuration" : "Edit Configuration")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameSection
                    providerSection
                    modelSection
                    parametersSection
                    if selectedProviderType == .anthropic {
                        thinkingSection
                    }
                    streamingSection
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existingConfig == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || selectedProviderID.isEmpty || selectedModelID.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 450)
        .onAppear { populateFromExisting() }
    }

    // MARK: - Sections

    private var nameSection: some View {
        LabeledContent("Name") {
            TextField("e.g. Claude Heavy, Local Fast", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var providerSection: some View {
        LabeledContent("Provider") {
            Picker("", selection: $selectedProviderID) {
                Text("Select a provider...").tag("")
                ForEach(llmKit.providers) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .labelsHidden()
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Model") {
                HStack(spacing: 4) {
                    TextField("model ID", text: $selectedModelID)
                        .textFieldStyle(.roundedBorder)

                    if !providerModels.isEmpty {
                        modelPickerMenu
                    }
                }
            }

            if let info = selectedModelInfo {
                modelInfoBar(for: info)
            }
        }
    }

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Temperature") {
                HStack {
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", temperature))
                        .monospacedDigit()
                        .frame(width: 30)
                }
            }

            LabeledContent("Max Output Tokens") {
                TextField("4096", value: $maxOutputTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            LabeledContent("Max Context Tokens") {
                TextField("128000", value: $maxContextTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
        }
    }

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Thinking Budget") {
                HStack(spacing: 8) {
                    TextField("0 = disabled", value: $thinkingBudget, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                    Button("1K") { thinkingBudget = 1_024 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("4K") { thinkingBudget = 4_096 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("16K") { thinkingBudget = 16_384 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Text("Extended thinking token budget (Anthropic only). Set to 0 to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var streamingSection: some View {
        Toggle("Streaming", isOn: $streaming)
    }

    // MARK: - Model Picker

    private var providerModels: [ModelInfo] {
        llmKit.models(for: selectedProviderID)
    }

    private var selectedModelInfo: ModelInfo? {
        llmKit.modelInfo(providerID: selectedProviderID, modelID: selectedModelID)
    }

    private var selectedProviderType: ProviderType? {
        llmKit.providers.first { $0.id == selectedProviderID }?.apiType
    }

    private var modelPickerMenu: some View {
        Menu(
            content: {
                ForEach(providerModels) { model in
                    Button(action: { selectModel(model) }) {
                        modelMenuLabel(for: model)
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
        .help("Select from available models")
    }

    private func modelMenuLabel(for model: ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.displayName)
                HStack(spacing: 6) {
                    if let size = model.sizeLabel {
                        Text(size).foregroundStyle(.secondary)
                    }
                    if let quant = model.quantizationLabel {
                        Text(quant).foregroundStyle(.secondary)
                    }
                    if !model.capabilities.enabledLabels.isEmpty {
                        Text(model.capabilities.enabledLabels.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if model.isNew {
                Text("New")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    private func modelInfoBar(for info: ModelInfo) -> some View {
        HStack(spacing: 12) {
            if let maxOut = info.maxOutputTokens {
                let exceeds = maxOutputTokens > maxOut
                HStack(spacing: 2) {
                    Text("Max output:")
                        .foregroundStyle(.secondary)
                    Text(formatTokenCount(maxOut))
                        .foregroundStyle(exceeds ? .red : .primary)
                }
            }
            if let maxIn = info.maxInputTokens {
                HStack(spacing: 2) {
                    Text("Context:")
                        .foregroundStyle(.secondary)
                    Text(formatTokenCount(maxIn))
                }
            }
            if !info.capabilities.enabledLabels.isEmpty {
                HStack(spacing: 2) {
                    ForEach(info.capabilities.enabledLabels, id: \.self) { label in
                        Text(label)
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

    // MARK: - Actions

    private func selectModel(_ model: ModelInfo) {
        selectedModelID = model.modelID
        // Auto-populate token limits from model info
        if let maxOut = model.maxOutputTokens {
            maxOutputTokens = maxOut
        }
        if let maxIn = model.maxInputTokens {
            maxContextTokens = maxIn
        }
    }

    private func populateFromExisting() {
        guard let config = existingConfig else { return }
        name = config.name
        selectedProviderID = config.providerID
        selectedModelID = config.modelID
        temperature = config.temperature
        maxOutputTokens = config.maxOutputTokens
        maxContextTokens = config.maxContextTokens
        thinkingBudget = config.thinkingBudget ?? 0
        streaming = config.streaming
    }

    private func save() {
        let config = ModelConfiguration(
            id: existingConfig?.id ?? UUID(),
            name: name,
            providerID: selectedProviderID,
            modelID: selectedModelID,
            temperature: temperature,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            thinkingBudget: thinkingBudget > 0 ? thinkingBudget : nil,
            streaming: streaming
        )
        onSave(config)
        onDismiss()
    }
}
