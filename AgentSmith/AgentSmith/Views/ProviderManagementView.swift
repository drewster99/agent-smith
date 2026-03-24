import SwiftUI
import SwiftLLMKit

/// CRUD list for managing LLM providers.
struct ProviderManagementView: View {
    @Bindable var llmKit: LLMKitManager
    @State private var editingProvider: ProviderEditorState?
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Providers")
                    .font(AppFonts.sectionHeader)
                Spacer()
                Button(action: { addProvider() }, label: {
                    Label("Add Provider", systemImage: "plus")
                })
            }

            if llmKit.providers.isEmpty {
                Text("No providers configured. Add one to get started.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(llmKit.providers) { provider in
                    providerRow(provider)
                }
            }
        }
        .sheet(item: $editingProvider) { state in
            ProviderEditorSheet(
                llmKit: llmKit,
                state: state,
                onDismiss: { editingProvider = nil }
            )
        }
        .alert("Delete Error", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        ), actions: {
            Button("OK") { deleteError = nil }
        }, message: {
            Text(deleteError ?? "")
        })
    }

    private func providerRow(_ provider: ModelProvider) -> some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text(provider.apiType.displayName)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(provider.endpoint.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("Edit") {
                    let apiKey = llmKit.apiKey(for: provider.id) ?? ""
                    editingProvider = ProviderEditorState(
                        mode: .edit,
                        id: provider.id,
                        name: provider.name,
                        apiType: provider.apiType,
                        endpointString: provider.endpoint.absoluteString,
                        apiKey: apiKey
                    )
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: {
                    deleteProvider(id: provider.id)
                }, label: {
                    Image(systemName: "trash")
                })
                .buttonStyle(.borderless)
            }
            .padding(4)
        }
    }

    private func addProvider() {
        editingProvider = ProviderEditorState(
            mode: .add,
            id: "provider-\(UUID().uuidString.prefix(8))",
            name: "",
            apiType: .anthropic,
            endpointString: "https://api.anthropic.com",
            apiKey: ""
        )
    }

    private func deleteProvider(id: String) {
        do {
            try llmKit.deleteProvider(id: id)
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Editor State

struct ProviderEditorState: Identifiable {
    enum Mode { case add, edit }
    let mode: Mode
    var id: String
    var name: String
    var apiType: ProviderType
    var endpointString: String
    var apiKey: String
}

// MARK: - Editor Sheet

private struct ProviderEditorSheet: View {
    let llmKit: LLMKitManager
    @State var state: ProviderEditorState
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.mode == .add ? "Add Provider" : "Edit Provider")
                .font(.title2.bold())

            LabeledContent("Name") {
                TextField("e.g. Anthropic, My Ollama Server", text: $state.name)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("API Type") {
                Picker("", selection: $state.apiType) {
                    ForEach(ProviderType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
            }

            LabeledContent("Endpoint") {
                HStack(spacing: 4) {
                    TextField("https://...", text: $state.endpointString)
                        .textFieldStyle(.roundedBorder)
                    endpointPresetMenu
                }
            }

            LabeledContent("API Key") {
                SecureField("Optional", text: $state.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(state.mode == .add ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.name.isEmpty || URL(string: state.endpointString) == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 450)
        .onChange(of: state.apiType) { _, newType in
            applyDefaultEndpoint(for: newType)
        }
        .alert("Save Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        ), actions: {
            Button("OK") { saveError = nil }
        }, message: {
            Text(saveError ?? "")
        })
    }

    private var endpointPresetMenu: some View {
        Menu(
            content: {
                Section("Cloud APIs") {
                    Button("Anthropic") {
                        state.endpointString = "https://api.anthropic.com"
                        state.apiType = .anthropic
                    }
                    Button("DeepSeek") {
                        state.endpointString = "https://api.deepseek.com"
                        state.apiType = .openAICompatible
                    }
                    Button("Google Gemini") {
                        state.endpointString = "https://generativelanguage.googleapis.com/v1beta"
                        state.apiType = .gemini
                    }
                    Button("Hugging Face") {
                        state.endpointString = "https://router.huggingface.co/v1"
                        state.apiType = .huggingFace
                    }
                    Button("Mistral") {
                        state.endpointString = "https://api.mistral.ai/v1"
                        state.apiType = .mistral
                    }
                    Button("OpenAI") {
                        state.endpointString = "https://api.openai.com/v1"
                        state.apiType = .openAICompatible
                    }
                    Button("xAI (Grok)") {
                        state.endpointString = "https://api.x.ai/v1"
                        state.apiType = .xAI
                    }
                    Button("Ollama (cloud)") {
                        state.endpointString = "https://ollama.com/api"
                        state.apiType = .ollama
                    }
                }
                Section("Local") {
                    Button("Ollama (local)") {
                        state.endpointString = "http://localhost:11434/api"
                        state.apiType = .ollama
                    }
                    Button("LM Studio") {
                        state.endpointString = "http://localhost:1234/v1"
                        state.apiType = .lmStudio
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

    private func applyDefaultEndpoint(for type: ProviderType) {
        switch type {
        case .anthropic:
            state.endpointString = "https://api.anthropic.com"
        case .openAICompatible:
            state.endpointString = "https://api.openai.com/v1"
        case .ollama:
            state.endpointString = "http://localhost:11434/api"
        case .mistral:
            state.endpointString = "https://api.mistral.ai/v1"
        case .gemini:
            state.endpointString = "https://generativelanguage.googleapis.com/v1beta"
        case .huggingFace:
            state.endpointString = "https://router.huggingface.co/v1"
        case .lmStudio:
            state.endpointString = "http://localhost:1234/v1"
        case .xAI:
            state.endpointString = "https://api.x.ai/v1"
        }
    }

    @State private var saveError: String?

    private func save() {
        guard let endpoint = URL(string: state.endpointString) else { return }
        let provider = ModelProvider(
            id: state.id,
            name: state.name,
            apiType: state.apiType,
            endpoint: endpoint
        )
        do {
            switch state.mode {
            case .add:
                try llmKit.addProvider(provider, apiKey: state.apiKey)
            case .edit:
                try llmKit.updateProvider(provider, apiKey: state.apiKey)
            }
            onDismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
