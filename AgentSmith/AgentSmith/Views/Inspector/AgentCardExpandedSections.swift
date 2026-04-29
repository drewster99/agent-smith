import SwiftUI
import AgentSmithKit

/// All sections that appear under an `AgentCard` when it is expanded inline (Jones, the
/// only role that doesn't open in a separate window). Drives `Available Tools`, security
/// `Evaluations` (Jones only), `Recent Tool Calls`, `Recent Messages`, `Context`, the
/// `LLM Turns` disclosure list, and the per-agent `Direct Message` input.
struct AgentCardExpandedSections: View {
    let role: AgentRole
    let availableTools: [String]
    let evaluationRecords: [EvaluationRecord]
    let recentToolUses: [ChannelMessage]
    let recentMessages: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let llmTurns: [LLMTurnRecord]
    @Binding var expandedTurnIDs: Set<UUID>
    let onSendDirectMessage: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !availableTools.isEmpty {
                InspectorSection(title: "Available Tools") {
                    AvailableToolsGrid(toolNames: availableTools)
                }
            }

            // Jones: evaluations are the primary work product, surface above tool calls.
            if role == .jones && !evaluationRecords.isEmpty {
                InspectorSection(title: "Security Evaluations (\(evaluationRecords.count))") {
                    ForEach(Array(evaluationRecords.suffix(10).reversed())) { record in
                        EvaluationRecordRow(record: record)
                    }
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
                    .frame(maxHeight: 300)
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
                    // Project rule: defer @State / @Binding mutations out of SwiftUI
                    // lifecycle closures so they can't race the active render pass.
                    if let last = llmTurns.last {
                        DispatchQueue.main.async { expandedTurnIDs.insert(last.id) }
                    }
                }
                .onChange(of: llmTurns.count) {
                    if let last = llmTurns.last {
                        DispatchQueue.main.async { expandedTurnIDs.insert(last.id) }
                    }
                }
            }

            // Direct message input — hidden for Jones since its filter drops private messages.
            if role != .jones {
                InspectorSection(title: "Direct Message") {
                    DirectMessageInputRow(
                        placeholder: "Message \(role.displayName) privately…",
                        onSend: onSendDirectMessage
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}
