import SwiftUI
import AgentSmithKit

/// Color-coded scrolling message stream with attachment display.
struct ChannelLogView: View {
    var messages: [ChannelMessage]

    @State private var isAtBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(messages) { message in
                        if shouldSuppress(message) {
                            // Folded into a tool_request row — don't render standalone
                        } else if case .string(let kind) = message.metadata?["messageKind"], kind == "agent_online" {
                            // Agent online announcements are internal coordination messages
                        } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_created" {
                            TaskCreatedBanner(title: message.content, timestamp: message.timestamp)
                                .id(message.id)
                        } else {
                            MessageRow(message: message, allMessages: messages)
                                .id(message.id)
                        }
                    }
                }
                .padding(8)
            }
            .background(AppColors.channelBackground)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Within 20pts of the bottom counts as "at bottom" to account for padding
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 20
            } action: { _, newValue in
                isAtBottom = newValue
            }
            .onChange(of: messages.count) {
                guard isAtBottom, let lastID = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    /// Suppresses security reviews and tool outputs that are grouped into a parent tool_request row.
    private func shouldSuppress(_ message: ChannelMessage) -> Bool {
        guard let reqID = message.stringMetadata("requestID") else { return false }
        let isFollowUp = message.metadata?["securityDisposition"] != nil
            || message.stringMetadata("messageKind") == "tool_output"
        guard isFollowUp else { return false }
        // Only suppress if the parent tool_request exists in the messages array
        return messages.contains { msg in
            msg.stringMetadata("messageKind") == "tool_request"
                && msg.stringMetadata("requestID") == reqID
        }
    }
}

private struct MessageRow: View {
    let message: ChannelMessage
    let allMessages: [ChannelMessage]

    @State private var isExpanded = false

    private var senderColor: Color {
        AppColors.color(for: message.sender)
    }

    private var recipientColor: Color {
        guard let recipient = message.recipient else { return .secondary }
        switch recipient {
        case .agent(let role): return AppColors.color(for: .agent(role))
        case .user: return AppColors.color(for: .user)
        }
    }

    private var messageKind: String? {
        message.stringMetadata("messageKind")
    }

    private var isToolRequest: Bool {
        messageKind == "tool_request"
    }

    private var isToolOutput: Bool {
        messageKind == "tool_output"
    }

    private var isSecurityReview: Bool {
        message.metadata?["securityDisposition"] != nil
    }

    private var isErrorMessage: Bool {
        if case .bool(let value) = message.metadata?["isError"] { return value }
        return false
    }

    /// True when Smith sends a private message directly to the user — these deserve visual emphasis.
    private var isSmithToUser: Bool {
        guard case .agent(.smith) = message.sender else { return false }
        guard case .user = message.recipient else { return false }
        return true
    }

    // MARK: - Tool request grouping

    private var requestID: String? {
        message.stringMetadata("requestID")
    }

    private var securityReviewMessage: ChannelMessage? {
        guard let reqID = requestID else { return nil }
        return allMessages.first { msg in
            msg.stringMetadata("requestID") == reqID
                && msg.metadata?["securityDisposition"] != nil
        }
    }

    private var toolOutputMessage: ChannelMessage? {
        guard let reqID = requestID else { return nil }
        return allMessages.first { msg in
            msg.stringMetadata("requestID") == reqID
                && msg.stringMetadata("messageKind") == "tool_output"
        }
    }

    private var dispositionIndicator: String? {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
        switch d {
        case "approved": return "\u{2705}"   // checkmark
        case "warning": return "\u{26A0}\u{FE0F}" // warning
        case "denied": return "\u{1F6AB}"    // prohibited
        case "abort": return "\u{1F6D1}"     // stop sign
        case "cancelled": return nil
        default: return nil
        }
    }

    private var dispositionComment: String? {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
        switch d {
        case "warning", "denied", "abort":
            // Use the full disposition message from metadata (includes retry instruction for WARN)
            if case .string(let msg) = review.metadata?["dispositionMessage"], !msg.isEmpty {
                return msg
            }
            return nil
        default:
            return nil
        }
    }

    private var dispositionCommentColor: Color {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return .secondary }
        switch d {
        case "warning": return .yellow
        case "denied": return .orange
        case "abort": return .red
        default: return .secondary
        }
    }

    private var outputIsTruncatable: Bool {
        toolOutputMessage?.metadata?["truncatedContent"] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Sender header: name, timestamp, and private indicator if applicable
            HStack(spacing: 6) {
                Text(message.sender.displayName)
                    .font(AppFonts.channelSender)
                    .foregroundStyle(senderColor)

                if message.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("\u{2192} \(message.recipient?.displayName ?? "private")")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(recipientColor)
                }

                Text(Self.timestampFormatter.string(from: message.timestamp))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }

            if isToolRequest {
                toolRequestBody
            } else if isToolOutput {
                // Standalone tool output (no parent tool_request found — edge case)
                standaloneToolOutput
            } else if isSecurityReview {
                // Standalone security review (no parent tool_request found — edge case)
                Text(message.content)
                    .font(AppFonts.channelBody)
                    .foregroundStyle(securityReviewColor)
            } else {
                MarkdownText(content: message.content, baseFont: AppFonts.channelBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.attachments.isEmpty {
                ForEach(message.attachments) { attachment in
                    AttachmentView(attachment: attachment)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background({
            if isErrorMessage { return AppColors.errorBackground }
            if isSmithToUser { return AppColors.smithToUserBackground }
            return Color.clear
        }())
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Tool request consolidated block

    @ViewBuilder
    private var toolRequestBody: some View {
        // Line 1: "Tool: shell: pwd ✅"
        HStack(spacing: 4) {
            Text("Tool: \(message.content)")
                .font(AppFonts.channelBody)
                .foregroundStyle(.secondary)
            if let indicator = dispositionIndicator {
                Text(indicator)
            }
        }

        // Disposition comment (for WARN/UNSAFE/ABORT)
        if let comment = dispositionComment {
            Text(comment)
                .font(AppFonts.channelBody.italic())
                .foregroundStyle(dispositionCommentColor)
                .padding(.leading, 12)
        }

        // Tool output (if approved and executed)
        if let output = toolOutputMessage {
            let displayText: String = {
                if isExpanded {
                    return output.content
                }
                if case .string(let truncated) = output.metadata?["truncatedContent"] {
                    return truncated
                }
                return output.content
            }()
            Text(displayText)
                .font(AppFonts.channelBody.monospaced())
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if outputIsTruncatable {
                Text(isExpanded ? "Show less" : "Show more")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(.leading, 12)
                    .onTapGesture { isExpanded.toggle() }
            }
        }
    }

    @ViewBuilder
    private var standaloneToolOutput: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(message.content)
                .font(AppFonts.channelBody.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } label: {
            if case .string(let toolName) = message.metadata?["tool"] {
                Text("Output: \(toolName)")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.secondary)
            } else {
                Text("Output")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SS"
        return f
    }()

    private var securityReviewColor: Color {
        guard case .string(let disposition) = message.metadata?["securityDisposition"] else {
            return .secondary
        }
        switch disposition {
        case "approved": return .green
        case "warning": return .yellow
        case "denied": return .orange
        case "abort": return .red
        default: return .secondary
        }
    }
}

// MARK: - ChannelMessage helper

private extension ChannelMessage {
    func stringMetadata(_ key: String) -> String? {
        if case .string(let value) = metadata?[key] { return value }
        return nil
    }
}

/// Visually distinct banner announcing a newly created task in the channel log.
private struct TaskCreatedBanner: View {
    let title: String
    let timestamp: Date

    private let accentColor = AppColors.taskCreatedAccent

    var body: some View {
        VStack(spacing: 0) {
            // Top rule
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accentColor)

                Text("New Task")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                Spacer()

                Text(Self.timestampFormatter.string(from: timestamp))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Text(title)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            // Bottom rule
            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SS"
        return f
    }()
}

/// Displays an attachment inline: images as thumbnails, other files as badges.
private struct AttachmentView: View {
    let attachment: Attachment

    @State private var imageData: Data?

    var body: some View {
        Group {
            if attachment.isImage {
                imageView
            } else {
                fileBadge
            }
        }
        .task {
            // Load image data on demand if not in memory
            if attachment.isImage, attachment.data == nil {
                imageData = Attachment.loadPersistedData(
                    id: attachment.id,
                    filename: attachment.filename
                )
            } else {
                imageData = attachment.data
            }
        }
    }

    private var imageView: some View {
        Group {
            if let data = imageData ?? attachment.data,
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                fileBadge
            }
        }
    }

    private var fileBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(attachment.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var iconName: String {
        if attachment.isPDF { return "doc.richtext" }
        if attachment.isImage { return "photo" }
        if attachment.mimeType.hasPrefix("text/") { return "doc.text" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }
}
