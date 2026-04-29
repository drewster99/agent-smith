import SwiftUI

/// Editable LLM system-prompt textarea inside the agent config sheet.
struct AgentConfigSystemPromptSection: View {
    @Binding var draftPrompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LLM System Prompt")
                .font(AppFonts.inspectorLabel.weight(.bold))
                .foregroundStyle(.secondary)
            TextEditor(text: $draftPrompt)
                .font(AppFonts.inspectorBody)
                .frame(maxWidth: .infinity, minHeight: 200)
                .scrollContentBackground(.hidden)
                .background(AppColors.subtleRowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
