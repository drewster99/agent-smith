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
    let speechController: SpeechController
    let onSendDirectMessage: (AgentRole, String) -> Void
    let onUpdateSystemPrompt: (AgentRole, String) -> Void
    let onUpdatePollInterval: (AgentRole, TimeInterval) -> Void
    let onUpdateMaxToolCalls: (AgentRole, Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Agents")
                    .font(AppFonts.sectionHeader)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                ForEach(AgentRole.allCases, id: \.self) { role in
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

                        Text(role.displayName)
                            .font(.headline)
                            .foregroundStyle(hasActivity ? roleColor : .secondary)

                        Spacer()

                        if isProcessing {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Thinking")
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

                    // For agents whose raw text is suppressed from the channel, surface recent
                    // LLM reasoning inline so it isn't invisible.
                    let llmOutputs = contextMessages.compactMap { msg -> String? in
                        guard msg.role == .assistant else { return nil }
                        switch msg.content {
                        case .text(let s): return s.isEmpty ? nil : s
                        case .mixed(let s, _): return s.isEmpty ? nil : s
                        default: return nil
                        }
                    }
                    let recentLLMOutputs = Array(llmOutputs.suffix(3).reversed())
                    if role == .jones && !recentLLMOutputs.isEmpty {
                        InspectorSection(title: "LLM Reasoning") {
                            ForEach(recentLLMOutputs.indices, id: \.self) { i in
                                LLMReasoningRow(text: recentLLMOutputs[i])
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

    @State private var expanded = false

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }, label: {
            HStack(alignment: .top, spacing: 5) {
                Text(roleLabel)
                    .font(AppFonts.inspectorBody.weight(.bold))
                    .foregroundStyle(roleColor)
                    .frame(width: 14, alignment: .center)
                    .help(roleTooltip)

                Text(expanded ? fullContent : contentSummary)
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        })
        .buttonStyle(.plain)
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
        case .system: return "System — the agent's system prompt"
        case .user: return "User — input from the user or channel messages"
        case .assistant: return "Assistant — the LLM's response (text or tool calls)"
        case .tool: return "Tool — result returned by a tool call"
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
        case .toolCalls(let calls): return calls.map { "[\($0.name)]" }.joined(separator: ", ")
        case .mixed(let text, let calls):
            return text + " " + calls.map { "[\($0.name)]" }.joined(separator: ", ")
        case .toolResult(let callID, let content):
            return "→ \(callID): \(content)"
        }
    }

    private func truncate(_ s: String) -> String {
        let limit = 120
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }
}

private struct LLMReasoningRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("LLM")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Text(text)
                .font(AppFonts.inspectorBody.italic())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private let inspectorTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SS"
    return f
}()

/// A single LLM turn entry in the per-turn inspection log.
private struct LLMTurnDisclosureRow: View {
    let turn: LLMTurnRecord
    let turnNumber: Int
    @Binding var isExpanded: Bool

    @State private var showingFullContext = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !turn.inputDelta.isEmpty {
                    Text("Input (\(turn.inputDelta.count) new msg\(turn.inputDelta.count == 1 ? "" : "s")):")
                        .font(AppFonts.inspectorLabel.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(turn.inputDelta.indices, id: \.self) { i in
                        ContextMessageRow(message: turn.inputDelta[i])
                    }
                }
                Text("Response:")
                    .font(AppFonts.inspectorLabel.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(responseSummary)
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                if !turn.contextSnapshot.isEmpty {
                    Button(action: { showingFullContext = true }) {
                        Label("View Full Context (\(turn.contextSnapshot.count))", systemImage: "doc.text.magnifyingglass")
                            .font(AppFonts.inspectorBody)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .padding(.top, 2)
                }
            }
            .padding(.top, 4)
            .padding(.leading, 8)
        } label: {
            Text(turnLabel)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .sheet(isPresented: $showingFullContext) {
            FullContextSheet(turn: turn, turnNumber: turnNumber)
        }
    }

    private var turnLabel: String {
        let ts = inspectorTimestampFormatter.string(from: turn.timestamp)
        let responseDesc: String
        switch turn.response {
        case .text: responseDesc = "text"
        case .toolCalls(let c): responseDesc = "\(c.count) tool call\(c.count == 1 ? "" : "s")"
        case .mixed(_, let c): responseDesc = "text + \(c.count) tool call\(c.count == 1 ? "" : "s")"
        }
        return "\(ts)  Turn \(turnNumber) · \(turn.inputDelta.count) in → \(responseDesc)"
    }

    private var responseSummary: String {
        switch turn.response {
        case .text(let s):
            return s
        case .toolCalls(let calls):
            return calls.map { "\($0.name)(\($0.arguments))" }.joined(separator: "\n\n")
        case .mixed(let text, let calls):
            let textPart = text.isEmpty ? "" : text + "\n\n"
            let callPart = calls.map { "\($0.name)(\($0.arguments))" }.joined(separator: "\n\n")
            return textPart + callPart
        }
    }
}

private struct FullContextSheet: View {
    let turn: LLMTurnRecord
    let turnNumber: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Context — Turn \(turnNumber)")
                        .font(.title3.bold())
                    Text("\(turn.contextSnapshot.count) messages · \(inspectorTimestampFormatter.string(from: turn.timestamp))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(turn.contextSnapshot.indices, id: \.self) { i in
                        ContextMessageRow(message: turn.contextSnapshot[i])
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 600, idealWidth: 800, minHeight: 400, idealHeight: 600)
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
