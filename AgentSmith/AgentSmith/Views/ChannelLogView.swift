import SwiftUI
import AgentSmithKit

/// Color-coded scrolling message stream with attachment display.
struct ChannelLogView: View {
    var messages: [ChannelMessage]
    var persistedHistoryCount: Int
    var hasRestoredHistory: Bool
    var onRestoreHistory: () -> Void

    @State private var isAtBottom = true
    @State private var autoScrollEnabled = true

    private struct ScrollMetrics: Equatable {
        var isNearBottom: Bool
        var contentHeight: CGFloat
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if persistedHistoryCount > 0 && !hasRestoredHistory {
                            Button(action: onRestoreHistory) {
                                Text("Restore full history (\(persistedHistoryCount) messages)")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.bottom, 4)
                        }

                        ForEach(messages) { message in
                            if shouldSuppress(message) {
                                // Folded into a tool_request row — don't render standalone
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "agent_online" {
                                // Agent online announcements are internal coordination messages
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_created" {
                                TaskCreatedBanner(
                                    title: message.content,
                                    description: message.stringMetadata("taskDescription"),
                                    timestamp: message.timestamp
                                )
                                    .id(message.id)
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_completed" {
                                TaskCompletedBanner(
                                    title: message.content,
                                    durationSeconds: message.doubleMetadata("durationSeconds"),
                                    timestamp: message.timestamp
                                )
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
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    let distanceFromBottom = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    let threshold = geometry.containerSize.height * 0.2
                    return ScrollMetrics(
                        isNearBottom: distanceFromBottom <= threshold,
                        contentHeight: geometry.contentSize.height
                    )
                } action: { old, new in
                    isAtBottom = new.isNearBottom
                    // Content grew but user didn't scroll -> keep auto-scroll on
                    // Content same but user scrolled away -> disable auto-scroll
                    if old.isNearBottom && !new.isNearBottom
                        && new.contentHeight == old.contentHeight {
                        autoScrollEnabled = false
                    }
                    if new.isNearBottom {
                        autoScrollEnabled = true
                    }
                }
                .onChange(of: messages.count) {
                    guard autoScrollEnabled, let lastID = messages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }

                if !isAtBottom {
                    Button {
                        guard let lastID = messages.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(radius: 2)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale))
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
    @State private var isHovering = false

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

    /// The security disposition string for this tool request's review, if any.
    private var securityDisposition: String? {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
        return d
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
        case "autoApproved": return "\u{2705}"  // checkmark (comment below explains auto-approval)
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
        case "autoApproved":
            return "Auto-approved (identical WARN retry)"
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
        case "autoApproved": return .green
        case "warning": return .orange
        case "denied": return .orange
        case "abort": return .red
        default: return .secondary
        }
    }

    /// Maximum characters for tool output before the view layer truncates.
    private static let outputTruncationLimit = 500

    private var outputIsTruncatable: Bool {
        if toolOutputMessage?.metadata?["truncatedContent"] != nil { return true }
        guard let output = toolOutputMessage else { return false }
        return output.content.count > Self.outputTruncationLimit
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
            switch securityDisposition {
            case "warning", "denied": return Color.orange.opacity(0.10)
            case "abort": return AppColors.errorBackground
            default: break
            }
            return Color.clear
        }())
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .onHover { isHovering = $0 }
    }

    /// Maximum characters to show for the tool call description before truncating.
    private static let toolCallTruncationLimit = 200

    /// Whether the tool call description is long enough to warrant truncation.
    private var toolCallIsTruncatable: Bool {
        message.content.count > Self.toolCallTruncationLimit
    }

    /// The tool call description, truncated if needed and not expanded.
    private var toolCallDisplayText: String {
        if !toolCallIsTruncatable || isExpanded {
            return message.content
        }
        return String(message.content.prefix(Self.toolCallTruncationLimit)) + "…"
    }

    // MARK: - Tool request consolidated block

    private var isFileWrite: Bool {
        message.stringMetadata("tool") == "file_write"
    }

    @ViewBuilder
    private var toolRequestBody: some View {
        if isFileWrite {
            fileWriteRequestBody
        } else {
            genericToolRequestBody
        }
    }

    // MARK: file_write display

    @ViewBuilder
    private var fileWriteRequestBody: some View {
        // Line 1: "file_write /dir/path/filename ⚡1/3 ✅ (show content)"
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            FileWritePathView(path: message.stringMetadata("fileWritePath") ?? "")
            if let badge = parallelBadge {
                Text("⚡\(badge)")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.cyan.opacity(0.15))
                    .clipShape(Capsule())
            }
            if let indicator = dispositionIndicator {
                Text(indicator)
            }
            if let content = message.stringMetadata("fileWriteContent"), !content.isEmpty {
                Text(isExpanded ? "(hide content)" : "(show content)")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .onTapGesture { isExpanded.toggle() }
            }
        }

        // Disposition comment (for WARN/UNSAFE/ABORT)
        if let comment = dispositionComment {
            Text(comment)
                .font(AppFonts.channelBody.italic())
                .foregroundStyle(dispositionCommentColor)
                .padding(.leading, 12)
        }

        // Expanded content
        if isExpanded, let content = message.stringMetadata("fileWriteContent") {
            Text(content)
                .font(AppFonts.channelBody.monospaced())
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }

        // Tool output (success/error message)
        if let output = toolOutputMessage {
            Text(output.content)
                .font(AppFonts.channelBody.monospaced())
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: generic tool display

    /// Whether this tool call was part of a parallel batch.
    private var parallelBadge: String? {
        guard case .int(let count) = message.metadata?["parallelCount"], count > 1,
              case .int(let index) = message.metadata?["parallelIndex"] else { return nil }
        return "\(index + 1)/\(count)"
    }

    @ViewBuilder
    private var genericToolRequestBody: some View {
        // Line 1: "Tool: shell: pwd ✅"
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Tool: \(toolCallDisplayText)")
                .font(AppFonts.channelBody)
                .foregroundStyle(.secondary)
            if let badge = parallelBadge {
                Text("⚡\(badge)")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.cyan.opacity(0.15))
                    .clipShape(Capsule())
            }
            if let indicator = dispositionIndicator {
                Text(indicator)
            }
        }

        if toolCallIsTruncatable {
            Text(isExpanded ? "Show less" : "Show more")
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.leading, 12)
                .onTapGesture { isExpanded.toggle() }
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
                    // Prefer expandedContent (capped excerpt) over raw content to avoid
                    // rendering megabytes of data (e.g., binary blobs from osascript).
                    if case .string(let expanded) = output.metadata?["expandedContent"] {
                        return expanded
                    }
                    return output.content
                }
                if case .string(let truncated) = output.metadata?["truncatedContent"] {
                    return truncated
                }
                // View-layer fallback for long single-line outputs without backend truncation
                if output.content.count > Self.outputTruncationLimit {
                    let remaining = output.content.count - Self.outputTruncationLimit
                    return String(output.content.prefix(Self.outputTruncationLimit)) + "… (\(remaining) more characters)"
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
        case "autoApproved": return .green
        case "warning": return .orange
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

    func doubleMetadata(_ key: String) -> Double? {
        switch metadata?[key] {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }
}

/// Visually distinct banner announcing a newly created task in the channel log.
private struct TaskCreatedBanner: View {
    let title: String
    let description: String?
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
                .padding(.bottom, description != nil ? 2 : 6)

            if let description {
                Text(description)
                    .font(AppFonts.channelBody.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

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

/// Gold/amber banner marking a task's completion in the channel log.
private struct TaskCompletedBanner: View {
    let title: String
    let durationSeconds: Double?
    let timestamp: Date

    private let accentColor = AppColors.taskCompletedAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accentColor)

                Text("Task Completed")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                if let duration = durationSeconds {
                    Text("(\(Self.formattedDuration(duration)))")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }

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

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        if minutes < 60 {
            return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
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

/// Renders a `file_write` path with colored directory components and a clickable filename.
/// If the path traversed a symlink (detected by checking the resolved path), shows the
/// symlink destination as a secondary label.
private struct FileWritePathView: View {
    let path: String

    private var url: URL { URL(fileURLWithPath: path) }

    /// Directory portion (everything before the last component).
    private var directory: String {
        guard !path.isEmpty else { return "" }
        let dir = (path as NSString).deletingLastPathComponent
        // Ensure trailing slash for visual consistency
        return dir.hasSuffix("/") ? dir : dir + "/"
    }

    /// The filename (last path component).
    private var filename: String {
        (path as NSString).lastPathComponent
    }

    /// If the path is a symlink (or contains symlinks), returns the resolved destination.
    private var symlinkDestination: String? {
        guard !path.isEmpty else { return nil }
        let resolved = url.resolvingSymlinksInPath().path
        let standardized = url.standardized.path
        return resolved != standardized ? resolved : nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("file_write ")
                .font(AppFonts.channelBody)
                .foregroundStyle(.secondary)

            Text(directory)
                .font(AppFonts.channelBody)
                .foregroundStyle(.secondary.opacity(0.7))

            Text(filename)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(.cyan)
                .onTapGesture { openInFinder() }

            if let dest = symlinkDestination {
                Text(" \u{2192} ")
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.secondary)
                Text(dest)
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.purple.opacity(0.8))
                    .onTapGesture { openInFinder(path: dest) }
            }
        }
    }

    private func openInFinder(path overridePath: String? = nil) {
        let targetPath = overridePath ?? path
        let targetURL = URL(fileURLWithPath: targetPath)
        if FileManager.default.fileExists(atPath: targetPath) {
            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
        }
    }
}
