import SwiftUI
import AgentSmithKit

/// Settings window for configuring LLM endpoints per agent role.
struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Agent LLM Configuration")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Configure the LLM endpoint for each agent role. Changes take effect on next start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                AgentConfigView(
                    roleName: "Smith (Orchestrator)",
                    roleColor: AppColors.smithAgent,
                    config: $viewModel.smithConfig
                )

                AgentConfigView(
                    roleName: "Brown (Executor)",
                    roleColor: AppColors.brownAgent,
                    config: $viewModel.brownConfig
                )

                AgentConfigView(
                    roleName: "Jones (Safety Monitor)",
                    roleColor: AppColors.jonesAgent,
                    config: $viewModel.jonesConfig
                )
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 600)
        .onChange(of: viewModel.smithConfig) {
            viewModel.persistLLMConfigs()
        }
        .onChange(of: viewModel.brownConfig) {
            viewModel.persistLLMConfigs()
        }
        .onChange(of: viewModel.jonesConfig) {
            viewModel.persistLLMConfigs()
        }
    }
}
