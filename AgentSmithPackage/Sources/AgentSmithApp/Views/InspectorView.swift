import SwiftUI
import AgentSmithKit

/// Inspector panel showing per-agent status: activity, recent messages, tool calls, and available tools.
struct InspectorView: View {
    let messages: [ChannelMessage]
    let processingRoles: Set<AgentRole>
    let agentToolNames: [AgentRole: [String]]

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

                    AgentCard(
                        role: role,
                        isProcessing: processingRoles.contains(role),
                        hasActivity: !roleMessages.isEmpty,
                        availableTools: agentToolNames[role] ?? [],
                        recentMessages: recentMessages,
                        recentToolUses: recentTools
                    )
                }
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
    }
}

private struct AgentCard: View {
    let role: AgentRole
    let isProcessing: Bool
    let hasActivity: Bool
    let availableTools: [String]
    let recentMessages: [ChannelMessage]
    let recentToolUses: [ChannelMessage]

    @State private var expanded = true

    private var roleColor: Color { AppColors.color(for: .agent(role)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Available tools are always shown once the agent has come online
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
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Divider()
        }
    }
}

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
                .lineLimit(3)
                .truncationMode(.tail)
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
