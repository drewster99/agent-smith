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
    @State private var extendedCacheTTL: Bool = false
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
                        cacheTTLSection
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
        .frame(minWidth: 600, minHeight: 450)
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

    /// Whether extended thinking is active, which locks temperature to 1.0 for Anthropic.
    private var isThinkingActive: Bool {
        selectedProviderType == .anthropic && thinkingBudget > 0
    }

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Temperature") {
                HStack {
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                        .disabled(isThinkingActive)
                    Text(String(format: "%.1f", temperature))
                        .monospacedDigit()
                        .frame(width: 30)
                        .foregroundStyle(isThinkingActive ? .secondary : .primary)
                }
            }
            .onChange(of: temperature) { _, newValue in
                if selectedProviderType == .anthropic && newValue != 1.0 {
                    thinkingBudget = 0
                }
            }

            LabeledContent("Max Output Tokens") {
                TextField("4096", value: $maxOutputTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: maxOutputTokens) { _, newValue in
                        maxOutputTokens = max(1, newValue)
                    }
            }

            LabeledContent("Max Context Tokens") {
                TextField("128000", value: $maxContextTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: maxContextTokens) { _, newValue in
                        maxContextTokens = max(1, newValue)
                    }
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
                        .onChange(of: thinkingBudget) { _, newValue in
                            if newValue > 0 {
                                thinkingBudget = max(1024, newValue)
                                temperature = 1.0
                            } else {
                                thinkingBudget = 0
                            }
                        }

                    Button("1K") { thinkingBudget = 1_024 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("4K") { thinkingBudget = 4_096 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("16K") { thinkingBudget = 16_384 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Off") { thinkingBudget = 0 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if isThinkingActive {
                Text("Thinking enabled — temperature locked to 1.0 (Anthropic requirement). Minimum budget: 1,024 tokens.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Extended thinking token budget (Anthropic only). Set to 0 to disable. Changing temperature disables thinking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cacheTTLSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Extended Prompt Cache (1 hour)", isOn: $extendedCacheTTL)
            Text("Use 1-hour cache TTL instead of the default 5-minute. Cached input tokens cost 2x the base price.")
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
                    if let inCost = model.inputCostPerMillionTokens,
                       let outCost = model.outputCostPerMillionTokens {
                        Text("\(formatCostPerMillion(inCost))/\(formatCostPerMillion(outCost)) per M")
                            .foregroundStyle(.green)
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
        HStack(spacing: 8) {
            if let maxOut = info.maxOutputTokens {
                let exceeds = maxOutputTokens > maxOut
                Text("Max output: \(formatTokenCount(maxOut))")
                    .foregroundStyle(exceeds ? .red : .secondary)
            }
            if let maxIn = info.maxInputTokens {
                Text("Context: \(formatTokenCount(maxIn))")
                    .foregroundStyle(.secondary)
            }
            ForEach(info.capabilities.enabledLabels, id: \.self) { label in
                Text(label)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if let inCost = info.inputCostPerMillionTokens,
               let outCost = info.outputCostPerMillionTokens {
                Text("\(formatCostPerMillion(inCost)) in / \(formatCostPerMillion(outCost)) out per M")
                    .foregroundStyle(.green)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
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
        // Auto-suggest a name when creating a new config and the user hasn't typed one yet.
        if existingConfig == nil && name.isEmpty {
            name = suggestedName(provider: selectedProviderID, model: model)
        }
    }

    /// Builds a suggested configuration name from the provider and model display name.
    private func suggestedName(provider providerID: String, model: ModelInfo) -> String {
        let providerName = llmKit.providers.first { $0.id == providerID }?.name
        let modelName = model.displayName
        if let providerName, !providerName.isEmpty {
            return "\(providerName) — \(modelName)"
        }
        return modelName
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
        extendedCacheTTL = config.extendedCacheTTL
        streaming = config.streaming
    }

    private func save() {
        let effectiveThinkingBudget: Int? = (selectedProviderType == .anthropic && thinkingBudget > 0) ? thinkingBudget : nil
        let config = ModelConfiguration(
            id: existingConfig?.id ?? UUID(),
            name: name,
            providerID: selectedProviderID,
            modelID: selectedModelID,
            temperature: temperature,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            thinkingBudget: effectiveThinkingBudget,
            extendedCacheTTL: selectedProviderType == .anthropic && extendedCacheTTL,
            streaming: streaming
        )
        onSave(config)
        onDismiss()
    }
}
