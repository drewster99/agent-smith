import SwiftUI
import AgentSmithKit

/// Standalone window showing full agent inspector detail for Smith or Brown.
struct AgentInspectorWindow: View {
    let viewModel: AppViewModel
    let role: AgentRole
    @Environment(\.dismiss) private var dismiss

    @State private var expandedTurnIDs: Set<UUID> = []

    private var roleColor: Color { AppColors.color(for: .agent(role)) }

    private var inspectorDisplayName: String {
        switch role {
        case .smith: return "Agent Smith"
        case .brown: return "Agent Brown"
        case .jones: return "Security Agent"
        case .summarizer: return "Summarizer"
        }
    }

    private var isProcessing: Bool { viewModel.processingRoles.contains(role) }
    private var availableTools: [String] { viewModel.agentToolNames[role] ?? [] }
    private var contextMessages: [LLMMessage] { viewModel.agentContexts[role] ?? [] }
    private var llmTurns: [LLMTurnRecord] { viewModel.agentTurns[role] ?? [] }

    private var roleMessages: [ChannelMessage] {
        viewModel.messages.filter {
            if case .agent(let r) = $0.sender { return r == role }
            return false
        }
    }
    private var hasActivity: Bool { !roleMessages.isEmpty }
    private var recentMessages: [ChannelMessage] { Array(roleMessages.suffix(10).reversed()) }
    private var recentToolUses: [ChannelMessage] {
        Array(roleMessages.filter { $0.metadata?["tool"] != nil }.suffix(5).reversed())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Circle()
                    .fill(hasActivity ? roleColor : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(inspectorDisplayName)
                    .font(.title2.bold())
                    .foregroundStyle(roleColor)

                Spacer()

                if isProcessing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                } else if hasActivity {
                    if availableTools.isEmpty && !contextMessages.isEmpty {
                        Text("Terminated")
                            .font(.headline)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Idle")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !availableTools.isEmpty {
                        InspectorSection(title: "Available Tools") {
                            AvailableToolsGrid(toolNames: availableTools)
                        }
                    }

                    if !recentToolUses.isEmpty {
                        InspectorSection(title: "Recent Tool Calls") {
                            ForEach(recentToolUses) { msg in
                                InspectorToolRow(message: msg)
                            }
                        }
                    }

                    if !recentMessages.isEmpty {
                        InspectorSection(title: "Recent Messages") {
                            ForEach(recentMessages) { msg in
                                InspectorMessageRow(message: msg)
                            }
                        }
                    }

                    if !contextMessages.isEmpty {
                        InspectorSection(title: "Context (\(contextMessages.count) entries)") {
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(contextMessages.indices, id: \.self) { i in
                                        ContextMessageRow(message: contextMessages[i])
                                    }
                                }
                            }
                            .frame(maxHeight: 400)
                        }
                    }

                    if !llmTurns.isEmpty {
                        InspectorSection(title: "LLM Turns (\(llmTurns.count))") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(llmTurns.enumerated()), id: \.element.id) { i, turn in
                                    LLMTurnDisclosureRow(
                                        turn: turn,
                                        turnNumber: i + 1,
                                        isExpanded: Binding(
                                            get: { expandedTurnIDs.contains(turn.id) },
                                            set: { expand in
                                                if expand { expandedTurnIDs.insert(turn.id) }
                                                else { expandedTurnIDs.remove(turn.id) }
                                            }
                                        )
                                    )
                                }
                            }
                        }
                        .onAppear {
                            if let last = llmTurns.last { expandedTurnIDs.insert(last.id) }
                        }
                        .onChange(of: llmTurns.count) {
                            if let last = llmTurns.last { expandedTurnIDs.insert(last.id) }
                        }
                    }

                    // Direct message input
                    InspectorSection(title: "Direct Message") {
                        DirectMessageInputRow(
                            placeholder: "Message \(role.displayName) privately…",
                            onSend: { text in
                                Task { await viewModel.sendDirectMessage(to: role, text: text) }
                            }
                        )
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 600, idealWidth: 800, minHeight: 500, idealHeight: 700)
    }

}
