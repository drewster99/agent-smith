import AVFoundation
import SwiftUI
import AgentSmithKit

/// Inspector panel showing per-agent status: activity, context, tools, and direct messaging.
struct InspectorView: View {
    let messages: [ChannelMessage]
    let processingRoles: Set<AgentRole>
    let agentToolNames: [AgentRole: [String]]
    let agentContexts: [AgentRole: [LLMMessage]]
    let agentTurns: [AgentRole: [LLMTurnRecord]]
    let agentPollIntervals: [AgentRole: TimeInterval]
    let agentMaxToolCalls: [AgentRole: Int]
    let jonesEvaluationRecords: [EvaluationRecord]
    let speechController: SpeechController
    let onSendDirectMessage: (AgentRole, String) -> Void
    let onUpdateSystemPrompt: (AgentRole, String) -> Void
    let onUpdatePollInterval: (AgentRole, TimeInterval) -> Void
    let onUpdateMaxToolCalls: (AgentRole, Int) -> Void

    /// Compact status label for the pinned status bar.
    private func statusLabel(for role: AgentRole) -> String {
        if processingRoles.contains(role) {
            return role == .jones ? "Evaluating" : (role == .summarizer ? "Summarizing" : "Thinking")
        }
        let roleMessages = messages.filter {
            if case .agent(let r) = $0.sender { return r == role }
            return false
        }
        if !roleMessages.isEmpty { return "Idle" }
        return "—"
    }

    private func statusColor(for role: AgentRole) -> Color {
        if processingRoles.contains(role) { return AppColors.color(for: .agent(role)) }
        let roleMessages = messages.filter {
            if case .agent(let r) = $0.sender { return r == role }
            return false
        }
        if !roleMessages.isEmpty { return AppColors.color(for: .agent(role)) }
        return Color.secondary.opacity(0.4)
    }

    private func displayName(for role: AgentRole) -> String {
        role == .jones ? "Security" : role.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned status bar — always visible
            VStack(alignment: .leading, spacing: 6) {
                Text("Agents")
                    .font(AppFonts.sectionHeader)

                HStack(spacing: 12) {
                    ForEach(AgentRole.allCases, id: \.self) { role in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusColor(for: role))
                                .frame(width: 6, height: 6)
                            Text(displayName(for: role))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(statusColor(for: role))
                        }
                        .help("\(displayName(for: role)): \(statusLabel(for: role))")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Scrollable agent details
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                ForEach(AgentRole.allCases.filter { $0 != .summarizer }, id: \.self) { role in
                    let roleMessages = messages.filter {
                        if case .agent(let r) = $0.sender { return r == role }
                        return false
                    }
                    let recentMessages = Array(roleMessages.suffix(5).reversed())
                    let recentTools = Array(
                        roleMessages.filter { $0.metadata?["tool"] != nil }.suffix(3).reversed()
                    )
                    let context = agentContexts[role] ?? []
                    let turns = agentTurns[role] ?? []
                    let pollInterval = agentPollIntervals[role] ?? 5
                    let maxToolCalls = agentMaxToolCalls[role] ?? 100
                    let currentSystemPrompt = context.first(where: { $0.role == .system })
                        .flatMap { $0.content.textValue } ?? ""

                    AgentCard(
                        role: role,
                        isProcessing: processingRoles.contains(role),
                        hasActivity: !roleMessages.isEmpty,
                        availableTools: agentToolNames[role] ?? [],
                        recentMessages: recentMessages,
                        recentToolUses: recentTools,
                        contextMessages: context,
                        llmTurns: turns,
                        evaluationRecords: role == .jones ? jonesEvaluationRecords : [],
                        currentSystemPrompt: currentSystemPrompt,
                        pollInterval: pollInterval,
                        maxToolCalls: maxToolCalls,
                        speechController: speechController,
                        onSendDirectMessage: { text in onSendDirectMessage(role, text) },
                        onUpdateSystemPrompt: { prompt in onUpdateSystemPrompt(role, prompt) },
                        onUpdatePollInterval: { interval in onUpdatePollInterval(role, interval) },
                        onUpdateMaxToolCalls: { count in onUpdateMaxToolCalls(role, count) }
                    )
                }

                SummarizerCard(
                    messages: messages,
                    isProcessing: processingRoles.contains(.summarizer)
                )
            }
        }
    }
    .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
    }
}

private struct AgentCard: View {
    let role: AgentRole
    let isProcessing: Bool
    let hasActivity: Bool
    let availableTools: [String]
    let recentMessages: [ChannelMessage]
    let recentToolUses: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let llmTurns: [LLMTurnRecord]
    let evaluationRecords: [EvaluationRecord]
    let currentSystemPrompt: String
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let speechController: SpeechController
    let onSendDirectMessage: (String) -> Void
    let onUpdateSystemPrompt: (String) -> Void
    let onUpdatePollInterval: (TimeInterval) -> Void
    let onUpdateMaxToolCalls: (Int) -> Void

    @State private var expanded = true
    @State private var showingConfig = false
    @State private var expandedTurnIDs: Set<UUID> = []

    private var roleColor: Color { AppColors.color(for: .agent(role)) }
    private var isSpeechEnabled: Bool { speechController.agentEnabled[role] ?? false }

    /// Display name override for the inspector panel.
    private var inspectorDisplayName: String {
        role == .jones ? "Security Agent" : role.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }, label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(hasActivity ? roleColor : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)

                        Text(inspectorDisplayName)
                            .font(.headline)
                            .foregroundStyle(hasActivity ? roleColor : .secondary)

                        Spacer()

                        if isProcessing {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(role == .jones ? "Evaluating" : "Thinking")
                                    .font(AppFonts.inspectorLabel)
                                    .foregroundStyle(.secondary)
                            }
                        } else if hasActivity {
                            if role != .jones && availableTools.isEmpty && !contextMessages.isEmpty {
                                Text("Terminated")
                                    .font(AppFonts.inspectorLabel)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("Idle")
                                    .font(AppFonts.inspectorLabel)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Not active")
                                .font(AppFonts.inspectorLabel)
                                .foregroundStyle(.tertiary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)

                Button(action: {
                    speechController.setEnabled(!isSpeechEnabled, for: role)
                }, label: {
                    Image(systemName: isSpeechEnabled ? "speaker.wave.1" : "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(isSpeechEnabled ? .green : Color.secondary.opacity(0.4))
                })
                .buttonStyle(.plain)
                .help(isSpeechEnabled ? "Mute \(role.displayName)" : "Unmute \(role.displayName)")

                Button(action: { showingConfig = true }, label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                })
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
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

                    // Jones: show security evaluation records instead of LLM context.
                    if role == .jones && !evaluationRecords.isEmpty {
                        InspectorSection(title: "Security Evaluations (\(evaluationRecords.count))") {
                            ForEach(Array(evaluationRecords.suffix(10).reversed())) { record in
                                EvaluationRecordRow(record: record)
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
                            if let last = llmTurns.last { expandedTurnIDs.insert(last.id) }
                        }
                        .onChange(of: llmTurns.count) {
                            if let last = llmTurns.last { expandedTurnIDs.insert(last.id) }
                        }
                    }

                    // Direct message input — hidden for Jones since its filter drops all private messages
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

            Divider()
        }
        .sheet(isPresented: $showingConfig) {
            AgentConfigSheet(
                role: role,
                roleColor: roleColor,
                initialSystemPrompt: currentSystemPrompt,
                initialPollInterval: pollInterval,
                initialMaxToolCalls: maxToolCalls,
                speechController: speechController,
                onSave: { prompt, interval, maxCalls in
                    onUpdateSystemPrompt(prompt)
                    onUpdatePollInterval(interval)
                    onUpdateMaxToolCalls(maxCalls)
                }
            )
        }
    }
}

// MARK: - Subviews

private struct AvailableToolsGrid: View {
    let toolNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(toolNames, id: \.self) { name in
                HStack(spacing: 5) {
                    Image(systemName: "wrench")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppFonts.inspectorLabel.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct InspectorToolRow: View {
    let message: ChannelMessage

    private var toolName: String {
        if case .string(let name) = message.metadata?["tool"] { return name }
        return "unknown"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(toolName)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.primary)
            Spacer()
            Text(message.timestamp, style: .time)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct InspectorMessageRow: View {
    let message: ChannelMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.content)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.primary)
            Text(message.timestamp, style: .time)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A single entry from an agent's LLM context window. Tap to expand the full content.
private struct ContextMessageRow: View {
    let message: LLMMessage
    /// Optional message index displayed before the role label (e.g. "#1").
    var index: Int?
    /// When true, the message starts fully expanded (used in FullContextSheet).
    var initiallyExpanded: Bool = false

    @State private var expanded = false

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }, label: {
            HStack(alignment: .top, spacing: 5) {
                if let index {
                    Text("#\(index)")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .trailing)
                }

                Text(roleLabel)
                    .font(AppFonts.inspectorBody.weight(.bold))
                    .foregroundStyle(roleColor)
                    .frame(width: 14, alignment: .center)

                if isTaskContext {
                    Text("TC")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.purple)
                        .help("Injected Task Context — dynamic state appended each turn")
                }

                Text(expanded ? fullContent : contentSummary)
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(roleTooltip)
        })
        .buttonStyle(.plain)
        .onAppear {
            if initiallyExpanded { expanded = true }
        }
    }

    /// Detects the `[Injected Task Context]` prefix added by Smith's per-turn injection.
    private var isTaskContext: Bool {
        guard message.role == .system else { return false }
        if case .text(let s) = message.content {
            return s.hasPrefix("[Injected Task Context]")
        }
        return false
    }

    private var roleLabel: String {
        switch message.role {
        case .system: return "S"
        case .user: return "U"
        case .assistant: return "A"
        case .tool: return "T"
        }
    }

    private var roleTooltip: String {
        switch message.role {
        case .system: return "S = System prompt — the agent's base instructions"
        case .user: return "U = User input — messages from the orchestrator, channel, or injected context"
        case .assistant: return "A = Assistant — the LLM's response (text and/or tool calls)"
        case .tool: return "T = Tool result — output returned by a tool call execution"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .system: return .secondary
        case .user: return .blue
        case .assistant: return .green
        case .tool: return .orange
        }
    }

    private var rowBackground: Color {
        switch message.role {
        case .system: return Color.secondary.opacity(0.05)
        case .user: return Color.blue.opacity(0.05)
        case .assistant: return Color.green.opacity(0.05)
        case .tool: return Color.orange.opacity(0.05)
        }
    }

    private var contentSummary: String {
        switch message.content {
        case .text(let s): return truncate(s)
        case .toolCalls(let calls): return calls.map { "[\($0.name)]" }.joined(separator: ", ")
        case .mixed(let text, let calls):
            return truncate(text) + " " + calls.map { "[\($0.name)]" }.joined(separator: ", ")
        case .toolResult(let callID, let content):
            return "→ \(String(callID.prefix(8))): \(truncate(content))"
        }
    }

    private var fullContent: String {
        switch message.content {
        case .text(let s): return s
        case .toolCalls(let calls):
            return calls.map { call in
                "\(call.name)(\(call.arguments))"
            }.joined(separator: "\n\n")
        case .mixed(let text, let calls):
            var parts = [text]
            parts.append(contentsOf: calls.map { "\($0.name)(\($0.arguments))" })
            return parts.joined(separator: "\n\n")
        case .toolResult(let callID, let content):
            return "→ \(callID):\n\(content)"
        }
    }

    private func truncate(_ s: String) -> String {
        let limit = 120
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }
}

/// A row showing a single security evaluation result from SecurityEvaluator.
private struct EvaluationRecordRow: View {
    let record: EvaluationRecord
    @State private var expanded = false

    private var dispositionLabel: String {
        if record.disposition.approved && record.disposition.isAutoApproval {
            return "AUTO"
        } else if record.disposition.approved {
            return "SAFE"
        } else if record.disposition.isWarning {
            return "WARN"
        } else {
            return "UNSAFE"
        }
    }

    private var dispositionColor: Color {
        if record.disposition.approved { return .green }
        if record.disposition.isWarning { return .orange }
        return .red
    }

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }, label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dispositionLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(dispositionColor.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text(record.toolName)
                        .font(AppFonts.inspectorBody.bold())
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(record.latencyMs)ms")
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    Text(record.timestamp, style: .time)
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.tertiary)
                }

                if expanded {
                    if !record.toolParams.isEmpty {
                        Text(record.toolParams)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                    Text("Response: \(record.response)")
                        .font(AppFonts.inspectorBody.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(dispositionColor.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
    }
}

private let inspectorTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SS"
    return f
}()

/// A single LLM turn entry in the per-turn inspection log.
///
/// Shows a clear Outgoing (what was sent) / Response (what came back) structure
/// with latency timing.
private struct LLMTurnDisclosureRow: View {
    let turn: LLMTurnRecord
    let turnNumber: Int
    @Binding var isExpanded: Bool

    @State private var showingFullContext = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                // --- Outgoing ---
                if !turn.inputDelta.isEmpty {
                    turnSectionHeader("Outgoing", icon: "arrow.up.circle.fill", color: .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(turn.inputDelta.indices, id: \.self) { i in
                            ContextMessageRow(message: turn.inputDelta[i])
                        }
                    }
                }

                // --- Response ---
                turnSectionHeader(
                    "Response",
                    icon: "arrow.down.circle.fill",
                    color: .green,
                    trailing: turn.latencyMs > 0 ? formatLatency(turn.latencyMs) : nil
                )

                // Reasoning (thinking)
                if let reasoning = turn.response.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.purple)
                        .italic()
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Tool calls
                if !turn.response.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(turn.response.toolCalls.enumerated()), id: \.offset) { _, call in
                            toolCallRow(call)
                        }
                    }
                }

                // Text response
                if let text = turn.response.text, !text.isEmpty {
                    Text(text)
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 4)
                }

                // Full context link
                if !turn.contextSnapshot.isEmpty {
                    Button(action: { showingFullContext = true }) {
                        Label("Full Context (\(turn.contextSnapshot.count) messages)", systemImage: "doc.text.magnifyingglass")
                            .font(AppFonts.inspectorBody)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .padding(.top, 2)
                }
            }
            .padding(.top, 4)
            .padding(.leading, 4)
        } label: {
            turnHeaderLabel
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .sheet(isPresented: $showingFullContext) {
            FullContextSheet(turn: turn, turnNumber: turnNumber)
        }
    }

    // MARK: - Subviews

    private var turnHeaderLabel: some View {
        HStack(spacing: 6) {
            Text("Turn \(turnNumber)")
                .font(AppFonts.inspectorBody.weight(.semibold))
                .foregroundStyle(.primary)

            if !turn.modelID.isEmpty {
                Text(turn.modelID)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(inspectorTimestampFormatter.string(from: turn.timestamp))
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)

            Spacer()

            if turn.latencyMs > 0 {
                Text(formatLatency(turn.latencyMs))
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            responseTypeBadge
        }
    }

    private var responseTypeBadge: some View {
        let r = turn.response
        let label: String
        let color: Color
        if !r.toolCalls.isEmpty, let text = r.text, !text.isEmpty {
            label = "text+\(r.toolCalls.count) calls"
            color = .orange
        } else if !r.toolCalls.isEmpty {
            label = "\(r.toolCalls.count) call\(r.toolCalls.count == 1 ? "" : "s")"
            color = .orange
        } else {
            label = "text"
            color = .green
        }
        return Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func turnSectionHeader(_ title: String, icon: String, color: Color, trailing: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(title)
                .font(AppFonts.inspectorLabel.weight(.semibold))
                .foregroundStyle(color)
            if let trailing {
                Spacer()
                Text(trailing)
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func toolCallRow(_ call: LLMToolCall) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(call.name)
                    .font(AppFonts.inspectorBody.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(call.arguments)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(4)
        .background(Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct FullContextSheet: View {
    let turn: LLMTurnRecord
    let turnNumber: Int

    @Environment(\.dismiss) private var dismiss
    @State private var allExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Context — Turn \(turnNumber)")
                        .font(.title3.bold())
                    Text("\(turn.contextSnapshot.count) messages · \(inspectorTimestampFormatter.string(from: turn.timestamp))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(allExpanded ? "Collapse All" : "Expand All") {
                    allExpanded.toggle()
                }
                .controlSize(.small)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            // Model / config info bar
            if !turn.modelID.isEmpty {
                modelInfoBar
                Divider()
            }

            // Legend
            HStack(spacing: 16) {
                legendItem("S", color: .secondary, label: "System prompt")
                legendItem("TC", color: .purple, label: "Task Context")
                legendItem("U", color: .blue, label: "User / orchestrator input")
                legendItem("A", color: .green, label: "Assistant (LLM response)")
                legendItem("T", color: .orange, label: "Tool result")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(turn.contextSnapshot.indices, id: \.self) { i in
                        ContextMessageRow(
                            message: turn.contextSnapshot[i],
                            index: i + 1,
                            initiallyExpanded: allExpanded
                        )
                        // Force re-creation when expand/collapse all toggles
                        .id("\(i)-\(allExpanded)")
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 700)
    }

    private var modelInfoBar: some View {
        HStack(spacing: 12) {
            Label(turn.modelID, systemImage: "cpu")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(turn.providerType)
                .font(.caption)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("temp \(String(format: "%.1f", turn.temperature))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("max \(turn.maxOutputTokens) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let thinking = turn.thinkingBudget, thinking > 0 {
                Text("thinking \(thinking)")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            if turn.latencyMs > 0 {
                Text(formatLatency(turn.latencyMs))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func legendItem(_ tag: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(AppFonts.inspectorBody.weight(.bold))
                .foregroundStyle(color)
                .frame(minWidth: 14, alignment: .center)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DirectMessageInputRow: View {
    let placeholder: String
    let onSend: (String) -> Void

    @State private var draftText = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $draftText)
                .textFieldStyle(.roundedBorder)
                .font(AppFonts.inspectorBody)
                .onSubmit { sendIfNotEmpty() }

            Button("Send") {
                sendIfNotEmpty()
            }
            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .controlSize(.small)
        }
    }

    private func sendIfNotEmpty() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        draftText = ""
    }
}

// MARK: - Config Sheet

private struct AgentConfigSheet: View {
    let role: AgentRole
    let roleColor: Color
    let speechController: SpeechController
    let onSave: (String, TimeInterval, Int) -> Void

    @State private var draftPrompt: String
    @State private var draftPollInterval: TimeInterval
    @State private var draftMaxToolCalls: Int
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @Environment(\.dismiss) private var dismiss

    init(
        role: AgentRole,
        roleColor: Color,
        initialSystemPrompt: String,
        initialPollInterval: TimeInterval,
        initialMaxToolCalls: Int,
        speechController: SpeechController,
        onSave: @escaping (String, TimeInterval, Int) -> Void
    ) {
        self.role = role
        self.roleColor = roleColor
        self.speechController = speechController
        self.onSave = onSave
        _draftPrompt = State(initialValue: initialSystemPrompt)
        _draftPollInterval = State(initialValue: initialPollInterval)
        _draftMaxToolCalls = State(initialValue: initialMaxToolCalls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(role.displayName) Configuration")
                    .font(.title3.bold())
                    .foregroundStyle(roleColor)
                Spacer()
                Button("Done") {
                    onSave(draftPrompt, draftPollInterval, draftMaxToolCalls)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Speech
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Speech")
                            .font(AppFonts.inspectorLabel.weight(.bold))
                            .foregroundStyle(.secondary)

                        VoicePickerRow(
                            voiceIdentifier: Binding(
                                get: { speechController.agentVoiceIdentifier[role] ?? "" },
                                set: { speechController.setVoice($0, for: role) }
                            ),
                            availableVoices: availableVoices,
                            onTest: { speechController.previewSpeech(for: role) }
                        )

                        ForEach(AgentSoundCategory.allCases.filter(\.supportsSpeech), id: \.self) { category in
                            Toggle(
                                "Speak \(category.displayName.lowercased())",
                                isOn: Binding(
                                    get: { speechController.soundConfig(for: role, category: category).speakEnabled },
                                    set: { speechController.setSpeakEnabled($0, for: role, category: category) }
                                )
                            )
                            .font(AppFonts.inspectorBody)
                        }
                    }

                    Divider()

                    // Sounds
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sounds")
                            .font(AppFonts.inspectorLabel.weight(.bold))
                            .foregroundStyle(.secondary)

                        ForEach(AgentSoundCategory.allCases, id: \.self) { category in
                            SoundPickerRow(
                                label: category.displayName,
                                soundName: Binding(
                                    get: { speechController.soundConfig(for: role, category: category).soundName },
                                    set: { speechController.setSoundName($0, for: role, category: category) }
                                ),
                                onPreview: { speechController.previewSound(named: $0) }
                            )
                        }
                    }

                    Divider()

                    // Responsiveness
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Responsiveness")
                            .font(AppFonts.inspectorLabel.weight(.bold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Text("Max Tool Calls / Response")
                                .font(AppFonts.inspectorBody)
                                .foregroundStyle(.secondary)
                            Stepper(
                                "\(draftMaxToolCalls)",
                                value: $draftMaxToolCalls,
                                in: 1...500,
                                step: 1
                            )
                            .labelsHidden()
                            Text("\(draftMaxToolCalls)")
                                .font(AppFonts.inspectorBody)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        HStack(spacing: 12) {
                            Text("Poll Interval")
                                .font(AppFonts.inspectorBody)
                                .foregroundStyle(.secondary)
                            Stepper(
                                "\(Int(draftPollInterval))s",
                                value: $draftPollInterval,
                                in: 1...300,
                                step: 1
                            )
                            .labelsHidden()
                            Text("\(Int(draftPollInterval)) seconds")
                                .font(AppFonts.inspectorBody)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Divider()

                    // LLM System Prompt
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LLM System Prompt")
                            .font(AppFonts.inspectorLabel.weight(.bold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draftPrompt)
                            .font(AppFonts.inspectorBody)
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .scrollContentBackground(.hidden)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 500, minHeight: 540)
        .onAppear {
            availableVoices = AVSpeechSynthesisVoice.speechVoices()
                .sorted { $0.name < $1.name }
        }
    }
}

// MARK: - Reusable Sound/Voice Components

/// A sound-effect picker with a label and preview button.
struct SoundPickerRow: View {
    let label: String
    @Binding var soundName: String
    let onPreview: (String) -> Void

    var body: some View {
        LabeledContent(label) {
            HStack {
                Picker("", selection: $soundName) {
                    Text("None").tag("")
                    ForEach(SpeechController.systemSoundNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button(action: { onPreview(soundName) }) {
                    Image(systemName: "play.circle")
                }
                .disabled(soundName.isEmpty)
                .buttonStyle(.borderless)
            }
        }
    }
}

/// A voice picker with a test-speech button.
struct VoicePickerRow: View {
    @Binding var voiceIdentifier: String
    let availableVoices: [AVSpeechSynthesisVoice]
    let onTest: () -> Void

    var body: some View {
        LabeledContent("Voice") {
            HStack {
                Picker("", selection: $voiceIdentifier) {
                    Text("System Default").tag("")
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button(action: onTest) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Test voice")
            }
        }
    }
}

// MARK: - Summarizer Card

/// Inspector card for the TaskSummarizer, matching AgentCard visual style.
///
/// The summarizer is transient (fires once per task completion), so it doesn't have
/// persistent context, tools, or LLM turns. Instead, we show activity history and stats.
private struct SummarizerCard: View {
    let messages: [ChannelMessage]
    let isProcessing: Bool

    @State private var expanded = true

    private var summarizerMessages: [ChannelMessage] {
        messages.filter {
            if case .agent(let r) = $0.sender { return r == .summarizer }
            return false
        }
    }

    private var hasActivity: Bool { !summarizerMessages.isEmpty }

    private var summaryCount: Int {
        summarizerMessages.filter {
            if case .string("task_summarized") = $0.metadata?["messageKind"] { return true }
            return false
        }.count
    }

    private var errorCount: Int {
        summarizerMessages.filter {
            if case .bool(true) = $0.metadata?["isError"] { return true }
            return false
        }.count
    }

    private static let roleColor = AppColors.summarizerAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — matches AgentCard header style
            HStack(spacing: 8) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }, label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(hasActivity ? Self.roleColor : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)

                        Text("Summarizer")
                            .font(.headline)
                            .foregroundStyle(hasActivity ? Self.roleColor : .secondary)

                        Spacer()

                        if isProcessing {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Summarizing")
                                    .font(AppFonts.inspectorLabel)
                                    .foregroundStyle(.secondary)
                            }
                        } else if hasActivity {
                            Text("Idle")
                                .font(AppFonts.inspectorLabel)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not active")
                                .font(AppFonts.inspectorLabel)
                                .foregroundStyle(.tertiary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                })
                .buttonStyle(.plain)

                Image(systemName: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .help("Coming soon")

                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .padding(.leading, 4)
                    .help("Coming soon")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Stats row
                    if hasActivity {
                        InspectorSection(title: "Activity") {
                            HStack(spacing: 12) {
                                Label("\(summaryCount) summarized", systemImage: "checkmark.circle.fill")
                                    .font(AppFonts.inspectorBody)
                                    .foregroundStyle(.green)
                                if errorCount > 0 {
                                    Label("\(errorCount) failed", systemImage: "xmark.circle.fill")
                                        .font(AppFonts.inspectorBody)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }

                    // Recent summaries
                    if hasActivity {
                        InspectorSection(title: "Recent (\(summarizerMessages.count))") {
                            ForEach(Array(summarizerMessages.suffix(8).reversed()), id: \.id) { msg in
                                SummarizerActivityRow(message: msg)
                            }
                        }
                    } else {
                        Text("No summarization activity yet.")
                            .font(AppFonts.inspectorBody)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Divider()
        }
    }
}

/// A single row in the summarizer activity log.
private struct SummarizerActivityRow: View {
    let message: ChannelMessage

    @State private var isExpanded = false

    private var isError: Bool {
        if case .bool(true) = message.metadata?["isError"] { return true }
        return false
    }

    private var taskID: String? {
        if case .string(let id) = message.metadata?["taskID"] { return id }
        return nil
    }

    private var latencyMs: Int? {
        if case .int(let ms) = message.metadata?["latencyMs"] { return ms }
        return nil
    }

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }, label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isError ? .red : .green)

                    Text(isExpanded ? message.content : String(message.content.prefix(80)) + (message.content.count > 80 ? "…" : ""))
                        .font(AppFonts.inspectorBody)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)

                    if let latencyMs {
                        Text(formatLatency(latencyMs))
                            .font(AppFonts.inspectorBody)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    if !isExpanded {
                        Text(message.timestamp, style: .time)
                            .font(AppFonts.inspectorBody)
                            .foregroundStyle(.tertiary)
                    }
                }

                if isExpanded, let taskID {
                    Text("Task: \(taskID)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(isError ? Color.red.opacity(0.05) : Color.green.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
    }
}

// MARK: - Shared Helpers

/// Formats a latency in milliseconds to a human-readable string (e.g. "342ms", "1.8s", "12s").
private func formatLatency(_ ms: Int) -> String {
    if ms < 1000 {
        return "\(ms)ms"
    } else if ms < 10_000 {
        return String(format: "%.1fs", Double(ms) / 1000.0)
    } else {
        return String(format: "%.0fs", Double(ms) / 1000.0)
    }
}
