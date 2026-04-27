import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Agent-centric model settings — provider, model, temperature, token limits, etc.
///
/// Mounted at the top of `AgentConfigSheet` (the gear-icon sheet on each agent card).
/// The user picks a model from a single dropdown sectioned by provider; the underlying
/// `ModelConfiguration` is created/cloned/updated transparently so the user never has
/// to think about configuration objects.
///
/// On appear, calls `viewModel.ensureDedicatedConfig(for:)` so any edits go to a config
/// owned exclusively by this role (clone-on-first-edit if shared).
///
/// Edits are auto-saved on commit — there is no separate Save button. The hosting sheet's
/// Done button only dismisses.
struct AgentModelSettingsSection: View {
    @Bindable var viewModel: AppViewModel
    let role: AgentRole

    @Environment(\.undoManager) private var undoManager

    @State private var configID: UUID?
    @State private var providerID: String = ""
    @State private var modelID: String = ""
    @State private var temperature: Double = 0.7
    @State private var maxOutputTokens: Int = 4096
    @State private var maxContextTokens: Int = 128_000
    @State private var thinkingBudget: Int = 0
    @State private var extendedCacheTTL: Bool = false
    @State private var useDefaultTemperature: Bool = false
    @State private var lastSavedAt: Date?

    /// Set during loadFromViewModel/syncDraftsFromConfig so that field `onChange`
    /// handlers don't fire `commit()` and create a phantom undo entry.
    @State private var isSyncingFromExternal = false

    private var llmKit: LLMKitManager { viewModel.shared.llmKit }

    private var selectedProvider: ModelProvider? {
        llmKit.providers.first { $0.id == providerID }
    }

    private var selectedAPIType: ProviderAPIType? {
        selectedProvider?.apiType
    }

    private var selectedModelInfo: ModelInfo? {
        llmKit.modelInfo(providerID: providerID, modelID: modelID)
    }

    /// All configured providers, sorted alphabetically. Previously this filtered to
    /// providers with at least one cached model, but that silently hid providers whose
    /// model fetch hadn't run (e.g. keys entered before per-provider refresh wiring,
    /// or days-old cached state that `refreshIfNeeded`'s YYYYMMDD gate skipped).
    /// We now show every provider and mark empty ones with a refresh affordance so
    /// the user can recover without leaving the sheet.
    private var sortedProviders: [ModelProvider] {
        llmKit.providers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var thinkingSupported: Bool {
        guard let api = selectedAPIType else { return false }
        return api == .anthropic || api == .alibabaCloud
    }

    private var thinkingActiveLocksTemperature: Bool {
        selectedAPIType == .anthropic && thinkingBudget > 0
    }

    private var anthropicCacheVisible: Bool {
        selectedAPIType == .anthropic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model")
                    .font(AppFonts.inspectorLabel.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if lastSavedAt != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("Saved")
                }
            }

            modelDropdown

            if let info = selectedModelInfo {
                modelInfoBar(for: info)
            } else if !modelID.isEmpty {
                Text("Model '\(modelID)' not found in the catalog. Refresh models in Settings → Configurations.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            parametersSection

            if thinkingSupported {
                thinkingSection
            }
            if anthropicCacheVisible {
                cacheTTLSection
            }
        }
        .onAppear { loadFromViewModel() }
        // Reflect external mutations of the assigned config (undo, redo, edits made
        // through the Configurations tab in another window) back into the local drafts.
        .onChange(of: observedConfig) { _, newConfig in
            if let newConfig {
                syncDraftsFromConfig(newConfig)
            }
        }
    }

    /// The currently-assigned `ModelConfiguration` for this role, observed reactively
    /// so that external mutations (e.g. via undo) trigger a draft re-sync.
    private var observedConfig: ModelConfiguration? {
        guard let id = configID else { return nil }
        return llmKit.configurations.first { $0.id == id }
    }

    /// Human-readable summary of the current selection for the dropdown's
    /// closed-state label. Always leads with the model id (that's the part the
    /// user actually picks per agent) and trails with the provider name in
    /// parentheses for disambiguation. Falls back to a hint when nothing is
    /// selected yet.
    private var menuLabelText: String {
        let providerName = selectedProvider?.name
        if modelID.isEmpty {
            return providerName.map { "Select a model… (\($0))" } ?? "Select a model…"
        }
        if let providerName {
            return "\(modelID)  ·  \(providerName)"
        }
        return modelID
    }

    // MARK: - Model dropdown (hierarchical: provider → models submenu)

    private var modelDropdown: some View {
        Menu(content: {
            if sortedProviders.isEmpty {
                Text("No providers configured. Add one in Settings → Providers.")
            } else {
                ForEach(sortedProviders) { provider in
                    providerSubmenu(for: provider)
                }
            }
        }, label: {
            HStack {
                // One Text node, model-first. The previous version stacked three
                // Text views in an HStack — under SwiftUI's `.borderlessButton`
                // menu style on macOS, the system rendered only the first node,
                // hiding the model name behind the provider. Building a single
                // String guarantees the actual selected model is always visible.
                Text(menuLabelText)
                    .foregroundStyle(modelID.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        })
        .menuStyle(.borderlessButton)
    }

    /// One provider's submenu in the model dropdown. Providers with a populated
    /// catalog get their model list. Providers with an empty catalog get a single
    /// "Refresh" action and a warning label so the user can pull models without
    /// leaving the sheet. A prior refresh error (from `llmKit.refreshErrors`) is
    /// shown inline so the failure mode is visible.
    @ViewBuilder
    private func providerSubmenu(for provider: ModelProvider) -> some View {
        let providerModels = llmKit.models(for: provider.id)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let refreshError = llmKit.refreshErrors[provider.name]
        let isEmpty = providerModels.isEmpty

        Menu(
            content: {
                if isEmpty {
                    if let refreshError {
                        Text("Last refresh failed: \(refreshError)")
                    } else {
                        Text("No models cached.")
                    }
                    Button("Refresh \(provider.name)") {
                        refreshProvider(provider)
                    }
                    .disabled(llmKit.isRefreshing)
                } else {
                    ForEach(providerModels) { model in
                        Button(
                            action: { selectModel(provider: provider, model: model) },
                            label: { modelMenuLabel(for: model) }
                        )
                    }
                    Divider()
                    Button("Refresh \(provider.name)") {
                        refreshProvider(provider)
                    }
                    .disabled(llmKit.isRefreshing)
                }
            },
            label: {
                HStack(spacing: 4) {
                    Text(provider.name)
                    if isEmpty || refreshError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        )
    }

    /// Kicks off a per-provider model refresh. `refreshModels(forProviderID:)` sets
    /// `llmKit.isRefreshing = true` for the duration, which the Refresh buttons
    /// key off via `.disabled(llmKit.isRefreshing)` so double-taps are prevented.
    private func refreshProvider(_ provider: ModelProvider) {
        let providerID = provider.id
        Task { @MainActor in
            await llmKit.refreshModels(forProviderID: providerID)
        }
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

    // MARK: - Parameters

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Temperature") {
                HStack {
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                        .disabled(thinkingActiveLocksTemperature || useDefaultTemperature)
                    Text(String(format: "%.1f", temperature))
                        .monospacedDigit()
                        .frame(width: 30)
                        .foregroundStyle((thinkingActiveLocksTemperature || useDefaultTemperature) ? .secondary : .primary)
                }
            }
            .onChange(of: temperature) { _, newValue in
                guard !isSyncingFromExternal else { return }
                if selectedAPIType == .anthropic && newValue != 1.0 {
                    thinkingBudget = 0
                }
                commit()
            }

            Toggle("Use model default temperature", isOn: $useDefaultTemperature)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(thinkingActiveLocksTemperature)
                .onChange(of: useDefaultTemperature) { _, _ in
                    guard !isSyncingFromExternal else { return }
                    commit()
                }

            LabeledContent("Max Output Tokens") {
                TextField("4096", value: $maxOutputTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit { commit() }
                    .onChange(of: maxOutputTokens) { _, newValue in
                        if newValue < 1 { maxOutputTokens = 1 }
                        guard !isSyncingFromExternal else { return }
                        commit()
                    }
            }

            LabeledContent("Max Context Tokens") {
                TextField("128000", value: $maxContextTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit { commit() }
                    .onChange(of: maxContextTokens) { _, newValue in
                        if newValue < 1 { maxContextTokens = 1 }
                        guard !isSyncingFromExternal else { return }
                        commit()
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
                        .onSubmit { commit() }
                        .onChange(of: thinkingBudget) { _, newValue in
                            // Two-phase clamp: if the typed value is below the 1024 floor
                            // (or negative), we rewrite it to the corrected value and bail
                            // out — the resulting state change re-fires this handler with
                            // the clamped value, which falls through to commit() once.
                            // No double-commit because the buttons no longer call commit()
                            // directly; they set state and let this handler do the work.
                            if newValue > 0 && newValue < 1024 {
                                thinkingBudget = 1024
                                return
                            }
                            if newValue < 0 {
                                thinkingBudget = 0
                                return
                            }
                            if newValue > 0 && selectedAPIType == .anthropic {
                                temperature = 1.0
                            }
                            guard !isSyncingFromExternal else { return }
                            commit()
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
            if thinkingActiveLocksTemperature {
                Text("Thinking enabled — temperature locked to 1.0 (Anthropic requirement). Minimum budget: 1,024 tokens.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if selectedAPIType == .alibabaCloud && thinkingBudget > 0 {
                Text("Thinking enabled for Alibaba Cloud (Qwen3/3.5). Minimum budget: 1,024 tokens.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Extended thinking token budget. Set to 0 to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cacheTTLSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Extended Prompt Cache (1 hour)", isOn: $extendedCacheTTL)
                .onChange(of: extendedCacheTTL) { _, _ in
                    guard !isSyncingFromExternal else { return }
                    commit()
                }
            Text("1-hour cache TTL instead of 5-minute. Cached input tokens cost 2x base price.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Model info bar

    private func modelInfoBar(for info: ModelInfo) -> some View {
        // Use a wrapping flow so the chips ride to subsequent rows when the
        // sheet is narrow rather than truncating into "Max ou…", "Conte…", etc.
        WrappingHStack(spacing: 8, lineSpacing: 4) {
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
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            let formatted = String(format: "%.1f", value)
            let label = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
            return "\(label)M"
        } else if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }

    // MARK: - Load / save

    private func loadFromViewModel() {
        let config = viewModel.ensureDedicatedConfig(for: role)
        configID = config.id
        syncDraftsFromConfig(config)
    }

    /// Copies field values from a `ModelConfiguration` into the local `@State` drafts
    /// without triggering field `onChange` handlers (which would re-commit and stack
    /// duplicate undo entries). Use this for initial load and external-change refresh.
    private func syncDraftsFromConfig(_ config: ModelConfiguration) {
        isSyncingFromExternal = true
        defer {
            // Defer back to the next runloop turn so all the @State setters above
            // have flushed their `onChange` notifications before we re-enable commit.
            DispatchQueue.main.async {
                self.isSyncingFromExternal = false
            }
        }
        providerID = config.providerID
        modelID = config.modelID
        temperature = config.temperature
        maxOutputTokens = config.maxOutputTokens
        maxContextTokens = config.maxContextTokens
        thinkingBudget = config.thinkingBudget ?? 0
        extendedCacheTTL = config.extendedCacheTTL
        useDefaultTemperature = config.useDefaultTemperature
    }

    private func selectModel(provider: ModelProvider, model: ModelInfo) {
        providerID = provider.id
        modelID = model.modelID
        if let maxOut = model.maxOutputTokens {
            maxOutputTokens = maxOut
        }
        if let maxIn = model.maxInputTokens {
            maxContextTokens = maxIn
        }
        commit()
    }

    /// Writes the current draft state back through `viewModel.updateAgentConfig` and
    /// registers an undo action that restores the previous configuration. Called from
    /// every field's `onChange` / `onSubmit`, plus from explicit-action buttons (model
    /// selection, thinking presets).
    ///
    /// No-op while `isSyncingFromExternal` is true so that draft updates from undo /
    /// external mutation don't recursively register fresh undo entries.
    private func commit() {
        guard !isSyncingFromExternal else { return }
        guard let configID else { return }
        guard let previous = llmKit.configurations.first(where: { $0.id == configID }) else { return }

        var updated = previous
        updated.providerID = providerID
        updated.modelID = modelID
        updated.temperature = temperature
        updated.maxOutputTokens = max(1, maxOutputTokens)
        updated.maxContextTokens = max(1, maxContextTokens)
        updated.thinkingBudget = (thinkingSupported && thinkingBudget > 0) ? thinkingBudget : nil
        updated.extendedCacheTTL = (selectedAPIType == .anthropic) && extendedCacheTTL
        updated.useDefaultTemperature = useDefaultTemperature

        // Skip if nothing meaningfully changed — saves both a redundant write and a
        // useless undo entry.
        if updated == previous { return }

        // updateAgentConfig handles undo registration internally when given a manager.
        viewModel.shared.updateAgentConfig(updated, undoManager: undoManager)
        lastSavedAt = Date()
    }
}

/// Horizontal stack that wraps to additional rows when its proposed width is too
/// narrow for the next subview. Drop-in replacement for a single-row `HStack` in
/// places like the model-info chips bar where truncation is worse than wrapping.
struct WrappingHStack: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 4) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineMaxHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAppended = lineWidth == 0 ? size.width : lineWidth + spacing + size.width
            if widthIfAppended <= maxWidth || lineWidth == 0 {
                lineWidth = widthIfAppended
                lineMaxHeight = max(lineMaxHeight, size.height)
            } else {
                totalHeight += lineMaxHeight + lineSpacing
                maxLineWidth = max(maxLineWidth, lineWidth)
                lineWidth = size.width
                lineMaxHeight = size.height
            }
        }
        totalHeight += lineMaxHeight
        maxLineWidth = max(maxLineWidth, lineWidth)
        return CGSize(width: min(maxLineWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineMaxHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAppended = x == bounds.minX ? size.width : (x - bounds.minX) + spacing + size.width
            if widthIfAppended > maxWidth && x > bounds.minX {
                x = bounds.minX
                y += lineMaxHeight + lineSpacing
                lineMaxHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += (x == bounds.minX ? 0 : spacing) + size.width
            lineMaxHeight = max(lineMaxHeight, size.height)
        }
    }
}
