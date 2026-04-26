import AVFoundation
import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Inspector panel showing per-agent status: activity, context, tools, and direct messaging.
struct InspectorView: View {
    let viewModel: AppViewModel

    var body: some View {
        let store = viewModel.inspectorStore
        VStack(spacing: 0) {
            Text("Agents")
                .font(AppFonts.sectionHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AgentRole.allCases.filter { $0 != .summarizer }, id: \.self) { role in
                        let roleMessages = viewModel.messages.filter {
                            if case .agent(let r) = $0.sender { return r == role }
                            return false
                        }
                        let recentMessages = Array(roleMessages.suffix(5).reversed())
                        let recentTools = Array(
                            roleMessages.filter { $0.metadata?["tool"] != nil }.suffix(3).reversed()
                        )
                        let context = store.contextMessages(for: role)
                        let turns = store.turnsByRole[role] ?? []
                        let pollInterval = viewModel.agentPollIntervals[role] ?? 5
                        let maxToolCalls = viewModel.agentMaxToolCalls[role] ?? 100
                        let currentSystemPrompt = store.systemPrompt(for: role)

                        AgentCard(
                            viewModel: viewModel,
                            role: role,
                            isProcessing: viewModel.processingRoles.contains(role),
                            hasActivity: !roleMessages.isEmpty,
                            availableTools: viewModel.agentToolNames[role] ?? [],
                            recentMessages: recentMessages,
                            recentToolUses: recentTools,
                            contextMessages: context,
                            llmTurns: turns,
                            modelConfig: viewModel.resolvedAgentConfigs[role],
                            evaluationRecords: role == .jones ? store.evaluationRecords : [],
                            currentSystemPrompt: currentSystemPrompt,
                            pollInterval: pollInterval,
                            maxToolCalls: maxToolCalls,
                            speechController: viewModel.shared.speechController,
                            onSendDirectMessage: { text in
                                Task { await viewModel.sendDirectMessage(to: role, text: text) }
                            },
                            onUpdateSystemPrompt: { prompt in
                                Task { await viewModel.updateSystemPrompt(for: role, prompt: prompt) }
                            },
                            onUpdatePollInterval: { interval in
                                Task { await viewModel.updatePollInterval(for: role, interval: interval) }
                            },
                            onUpdateMaxToolCalls: { count in
                                Task { await viewModel.updateMaxToolCalls(for: role, count: count) }
                            }
                        )
                    }

                    SummarizerCard(
                        viewModel: viewModel,
                        messages: viewModel.messages,
                        isProcessing: viewModel.processingRoles.contains(.summarizer),
                        currentSystemPrompt: store.systemPrompt(for: .summarizer),
                        pollInterval: viewModel.agentPollIntervals[.summarizer] ?? 5,
                        maxToolCalls: viewModel.agentMaxToolCalls[.summarizer] ?? 100,
                        speechController: viewModel.shared.speechController,
                        onUpdateSystemPrompt: { prompt in
                            Task { await viewModel.updateSystemPrompt(for: .summarizer, prompt: prompt) }
                        },
                        onUpdatePollInterval: { interval in
                            Task { await viewModel.updatePollInterval(for: .summarizer, interval: interval) }
                        },
                        onUpdateMaxToolCalls: { count in
                            Task { await viewModel.updateMaxToolCalls(for: .summarizer, count: count) }
                        }
                    )
                }
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
    }
}

private struct AgentCard: View {
    @Bindable var viewModel: AppViewModel
    let role: AgentRole
    let isProcessing: Bool
    let hasActivity: Bool
    let availableTools: [String]
    let recentMessages: [ChannelMessage]
    let recentToolUses: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let llmTurns: [LLMTurnRecord]
    let modelConfig: ModelConfiguration?
    let evaluationRecords: [EvaluationRecord]
    let currentSystemPrompt: String
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let speechController: SpeechController
    let onSendDirectMessage: (String) -> Void
    let onUpdateSystemPrompt: (String) -> Void
    let onUpdatePollInterval: (TimeInterval) -> Void
    let onUpdateMaxToolCalls: (Int) -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var expanded = true
    @State private var processingStartDate: Date?
    @State private var showingConfig = false
    @State private var expandedTurnIDs: Set<UUID> = []

    /// Smith and Brown open in a separate window; Jones expands inline.
    private var opensInWindow: Bool { role == .smith || role == .brown }

    private var roleColor: Color { AppColors.color(for: .agent(role)) }
    private var isSpeechEnabled: Bool { speechController.agentEnabled[role] ?? false }

    /// Display name override for the inspector panel.
    private var inspectorDisplayName: String {
        switch role {
        case .smith: return "Agent Smith"
        case .brown: return "Agent Brown"
        case .jones: return "Security Agent"
        case .summarizer: return "Summarizer"
        }
    }

    /// Actual input token count from the most recent LLM turn, if available.
    private var lastInputTokens: Int? {
        llmTurns.last?.usage?.inputTokens
    }

    /// Context usage percentage based on actual token counts from the provider.
    private var contextPercent: Int? {
        guard let config = modelConfig, config.maxContextTokens > 0,
              let inputTokens = lastInputTokens else { return nil }
        return min(100, (inputTokens * 100) / config.maxContextTokens)
    }

    @State private var showingModelStats = false

    private func modelInfoLine(config: ModelConfiguration) -> some View {
        let contextLabel = Self.formatTokenCount(config.maxContextTokens)
        return HStack(spacing: 6) {
            Text(config.modelID)
                .lineLimit(1)
                .truncationMode(.middle)
                .onTapGesture { showingModelStats = true }
                .popover(isPresented: $showingModelStats, arrowEdge: .bottom) {
                    ModelStatsPopover(turns: llmTurns, modelID: config.modelID, role: role)
                }
            Spacer()
            if let pct = contextPercent, let tokens = lastInputTokens {
                Text("\(Self.formatTokenCount(tokens)) / \(contextLabel) (\(pct)%)")
            } else {
                Text("\(contextLabel) ctx")
            }
        }
        .font(AppFonts.inspectorLabel)
        .foregroundStyle(.tertiary)
    }

    /// Formats a token count as a compact label (e.g. 128000 → "128K", 1048576 → "1.0M").
    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            let formatted = String(format: "%.1f", value)
            // Drop trailing ".0" for clean round numbers.
            let label = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
            return "\(label)M"
        } else if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Button(action: {
                    if opensInWindow {
                        openWindow(value: AgentInspectorTarget(sessionID: viewModel.session.id, role: role))
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
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
                                if let start = processingStartDate {
                                    ThinkingElapsedTime(since: start, font: AppFonts.inspectorLabel)
                                }
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

                        if opensInWindow {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
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

            // Model info subtitle — aligned with agent name text (past the dot)
            if let config = modelConfig {
                modelInfoLine(config: config)
                    .padding(.leading, 28) // 12 (container) + 8 (dot) + 8 (spacing)
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
            }

            if expanded && !opensInWindow {
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
                viewModel: viewModel,
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
        .onAppear { if isProcessing { processingStartDate = Date() } }
        .onChange(of: isProcessing) { _, newValue in
            processingStartDate = newValue ? Date() : nil
        }
    }
}

// MARK: - Shared Views

/// Shows elapsed time (MM:SS) after 5 seconds of processing. Updates every second.
struct ThinkingElapsedTime: View {
    let since: Date
    let font: Font

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { timeline in
            let elapsed = Int(timeline.date.timeIntervalSince(since))
            if elapsed >= 5 {
                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Subviews

struct AvailableToolsGrid: View {
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

struct InspectorSection<Content: View>: View {
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

struct InspectorToolRow: View {
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

struct InspectorMessageRow: View {
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
struct ContextMessageRow: View {
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
struct LLMTurnDisclosureRow: View {
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

struct FullContextSheet: View {
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
                        .id("\(i)-\(allExpanded)")
                    }

                    // Show the LLM response at the end of the context
                    if let responseMessage = responseAsMessage {
                        Divider()
                            .padding(.vertical, 4)

                        Text("Response")
                            .font(.caption.bold())
                            .foregroundStyle(.green)

                        ContextMessageRow(
                            message: responseMessage,
                            index: turn.contextSnapshot.count + 1,
                            initiallyExpanded: allExpanded
                        )
                        .id("response-\(allExpanded)")
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 700)
    }

    /// Converts the LLM response into an LLMMessage for display in the context view.
    private var responseAsMessage: LLMMessage? {
        let response = turn.response
        if !response.toolCalls.isEmpty {
            if let text = response.text, !text.isEmpty {
                return LLMMessage(role: .assistant, content: .mixed(text: text, toolCalls: response.toolCalls))
            }
            return LLMMessage(role: .assistant, content: .toolCalls(response.toolCalls))
        } else if let text = response.text, !text.isEmpty {
            return LLMMessage(role: .assistant, text: text)
        }
        return nil
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

struct DirectMessageInputRow: View {
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
    @Bindable var viewModel: AppViewModel
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
        viewModel: AppViewModel,
        role: AgentRole,
        roleColor: Color,
        initialSystemPrompt: String,
        initialPollInterval: TimeInterval,
        initialMaxToolCalls: Int,
        speechController: SpeechController,
        onSave: @escaping (String, TimeInterval, Int) -> Void
    ) {
        self.viewModel = viewModel
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
                    // Model — agent-centric provider/model/tuning controls. Reads & writes
                    // the dedicated configuration for this role via viewModel helpers.
                    AgentModelSettingsSection(viewModel: viewModel, role: role)

                    Divider()

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
        .frame(minWidth: 560, idealWidth: 720, minHeight: 540, idealHeight: 720)
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

    private var displaySelection: Binding<String> {
        Binding(
            get: {
                if voiceIdentifier.isEmpty { return "" }
                return availableVoices.contains { $0.identifier == voiceIdentifier } ? voiceIdentifier : ""
            },
            set: { voiceIdentifier = $0 }
        )
    }

    var body: some View {
        LabeledContent("Voice") {
            HStack {
                Picker("", selection: displaySelection) {
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
    @Bindable var viewModel: AppViewModel
    let messages: [ChannelMessage]
    let isProcessing: Bool
    let currentSystemPrompt: String
    let pollInterval: TimeInterval
    let maxToolCalls: Int
    let speechController: SpeechController
    let onUpdateSystemPrompt: (String) -> Void
    let onUpdatePollInterval: (TimeInterval) -> Void
    let onUpdateMaxToolCalls: (Int) -> Void

    @State private var expanded = true
    @State private var showingConfig = false

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
                    .help("Speech configuration coming soon")

                Button(action: { showingConfig = true }, label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                })
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .help("Configure summarizer")
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
        .sheet(isPresented: $showingConfig) {
            AgentConfigSheet(
                viewModel: viewModel,
                role: .summarizer,
                roleColor: Self.roleColor,
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

// MARK: - Model Stats Popover

/// Aggregated stats computed from LLM turn records for a given agent role.
private struct ModelStats {
    let totalCalls: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let totalToolCalls: Int
    let avgLatencyMs: Int
    let maxLatencyMs: Int
    let contextResets: Int

    // Per-call extremes
    let maxInputTokens: Int
    let maxOutputTokens: Int
    let lastInputTokens: Int
    let lastOutputTokens: Int
    let lastCacheReadTokens: Int

    /// Input tokens minus cache read and cache write (billed at full input rate).
    var uncachedInputTokens: Int {
        max(0, totalInputTokens - totalCacheReadTokens - totalCacheWriteTokens)
    }

    /// Combined input + output.
    var totalTokens: Int { totalInputTokens + totalOutputTokens }

    /// Fraction of input served from cache.
    var cacheHitRate: Double {
        guard totalInputTokens > 0 else { return 0 }
        return Double(totalCacheReadTokens) / Double(totalInputTokens)
    }

    var avgInputTokens: Int { totalCalls > 0 ? totalInputTokens / totalCalls : 0 }
    var avgOutputTokens: Int { totalCalls > 0 ? totalOutputTokens / totalCalls : 0 }

    init(turns: [LLMTurnRecord]) {
        totalCalls = turns.count
        totalInputTokens = turns.compactMap(\.usage?.inputTokens).reduce(0, +)
        totalOutputTokens = turns.compactMap(\.usage?.outputTokens).reduce(0, +)
        totalCacheReadTokens = turns.compactMap(\.usage?.cacheReadTokens).reduce(0, +)
        totalCacheWriteTokens = turns.compactMap(\.usage?.cacheWriteTokens).reduce(0, +)
        totalToolCalls = turns.reduce(0) { $0 + $1.response.toolCalls.count }
        let latencies = turns.map(\.latencyMs).filter { $0 > 0 }
        avgLatencyMs = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count
        maxLatencyMs = latencies.max() ?? 0

        maxInputTokens = turns.compactMap(\.usage?.inputTokens).max() ?? 0
        maxOutputTokens = turns.compactMap(\.usage?.outputTokens).max() ?? 0

        let last = turns.last
        lastInputTokens = last?.usage?.inputTokens ?? 0
        lastOutputTokens = last?.usage?.outputTokens ?? 0
        lastCacheReadTokens = last?.usage?.cacheReadTokens ?? 0

        // Count turns where input tokens dropped significantly (context reset indicator)
        var resets = 0
        var prevInput = 0
        for turn in turns {
            let input = turn.usage?.inputTokens ?? 0
            if prevInput > 0 && input < prevInput / 2 { resets += 1 }
            prevInput = input
        }
        contextResets = resets
    }
}

/// Popover showing aggregated session statistics for an agent's model usage.
private struct ModelStatsPopover: View {
    let turns: [LLMTurnRecord]
    let modelID: String
    let role: AgentRole

    private var stats: ModelStats { ModelStats(turns: turns) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(role.displayName) — Session Stats")
                .font(.headline)

            Text(modelID)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                // -- Overview --
                sectionHeader("Overview")
                statRow("LLM calls", "\(stats.totalCalls)")
                statRow("Tool calls issued", "\(stats.totalToolCalls)")
                statRow("Context resets", "\(stats.contextResets)")

                // -- Latency --
                GridRow { Divider().gridCellColumns(2) }
                sectionHeader("Latency")
                statRow("Avg response time", formatLatency(stats.avgLatencyMs))
                statRow("Max response time", formatLatency(stats.maxLatencyMs))

                // -- Token Totals --
                GridRow { Divider().gridCellColumns(2) }
                sectionHeader("Token Totals")
                statRow("Total tokens", formatCount(stats.totalTokens))
                statRow("Input tokens", formatCount(stats.totalInputTokens))
                statRow("Output tokens", formatCount(stats.totalOutputTokens))

                // -- Cache Breakdown --
                if stats.totalCacheReadTokens > 0 || stats.totalCacheWriteTokens > 0 {
                    GridRow { Divider().gridCellColumns(2) }
                    sectionHeader("Cache")
                    statRow("Uncached input", formatCount(stats.uncachedInputTokens))
                    statRow("Cache read", formatCount(stats.totalCacheReadTokens))
                    statRow("Cache write", formatCount(stats.totalCacheWriteTokens))
                    statRow("Cache hit rate", formatPercent(stats.cacheHitRate))
                }

                // -- Per-Call Averages --
                GridRow { Divider().gridCellColumns(2) }
                sectionHeader("Per-Call Averages")
                statRow("Avg input / call", formatCount(stats.avgInputTokens))
                statRow("Avg output / call", formatCount(stats.avgOutputTokens))

                // -- Per-Call Extremes --
                GridRow { Divider().gridCellColumns(2) }
                sectionHeader("Per-Call Max")
                statRow("Max input", formatCount(stats.maxInputTokens))
                statRow("Max output", formatCount(stats.maxOutputTokens))

                // -- Last Turn --
                if stats.totalCalls > 0 {
                    GridRow { Divider().gridCellColumns(2) }
                    sectionHeader("Last Turn")
                    statRow("Input", formatCount(stats.lastInputTokens))
                    statRow("Output", formatCount(stats.lastOutputTokens))
                    if stats.lastCacheReadTokens > 0 {
                        statRow("Cache read", formatCount(stats.lastCacheReadTokens))
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 260)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .gridCellColumns(2)
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func formatLatency(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
