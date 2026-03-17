import SwiftUI
import AgentSmithKit

/// Endpoint/model/key fields for configuring a single agent role's LLM.
struct AgentConfigView: View {
    let roleName: String
    let roleColor: Color
    @Binding var config: LLMConfiguration

    /// Two-way binding between the URL and a text field string.
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

                LabeledContent("Endpoint") {
                    TextField("http://localhost:11434/v1", text: endpointBinding)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("API Key") {
                    SecureField("Optional", text: $config.apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Model") {
                    TextField("llama3.1", text: $config.model)
                        .textFieldStyle(.roundedBorder)
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
    }
}
