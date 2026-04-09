import SwiftUI
import AgentSmithKit

/// Shared timestamp formatter used by all banner and message row structs in this file.
private let sharedTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SS"
    return f
}()

/// Color-coded scrolling message stream with attachment display.
struct ChannelLogView: View, Equatable {
    var messages: [ChannelMessage]
    var persistedHistoryCount: Int
    var hasRestoredHistory: Bool
    var onRestoreHistory: () -> Void

    @State private var isAtBottom = true
    @State private var autoScrollEnabled = true
    /// The attachment currently shown in the full-screen image viewer, managed by the parent.
    @Binding var selectedImageAttachment: Attachment?

    /// Prevents body re-evaluation when only unrelated parent properties change (e.g. inputText).
    /// Closures and Bindings are excluded — they can't be meaningfully compared, and
    /// the Binding manages its own invalidation internally.
    nonisolated static func == (lhs: ChannelLogView, rhs: ChannelLogView) -> Bool {
        lhs.messages.count == rhs.messages.count
        && lhs.messages.last?.id == rhs.messages.last?.id
        && lhs.persistedHistoryCount == rhs.persistedHistoryCount
        && lhs.hasRestoredHistory == rhs.hasRestoredHistory
    }

    private struct ScrollMetrics: Equatable {
        var isNearBottom: Bool
        var contentHeight: CGFloat
    }

    /// Set of requestIDs that have a corresponding `tool_request` message.
    /// Pre-computed once per body evaluation to avoid O(N) scans per row.
    private var toolRequestIDs: Set<String> {
        var ids = Set<String>()
        for msg in messages {
            if msg.stringMetadata("messageKind") == "tool_request",
               let reqID = msg.stringMetadata("requestID") {
                ids.insert(reqID)
            }
        }
        return ids
    }

    /// Maps requestID to security review messages for O(1) lookup by MessageRow.
    private var securityReviewByRequestID: [String: ChannelMessage] {
        var dict: [String: ChannelMessage] = [:]
        for msg in messages {
            if msg.metadata?["securityDisposition"] != nil,
               let reqID = msg.stringMetadata("requestID") {
                dict[reqID] = msg
            }
        }
        return dict
    }

    /// Maps requestID to tool output messages for O(1) lookup by MessageRow.
    private var toolOutputByRequestID: [String: ChannelMessage] {
        var dict: [String: ChannelMessage] = [:]
        for msg in messages {
            if msg.stringMetadata("messageKind") == "tool_output",
               let reqID = msg.stringMetadata("requestID") {
                dict[reqID] = msg
            }
        }
        return dict
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

                        let requestIDs = toolRequestIDs
                        let reviewLookup = securityReviewByRequestID
                        let outputLookup = toolOutputByRequestID

                        ForEach(messages) { message in
                            if shouldSuppress(message, toolRequestIDs: requestIDs) {
                                // Folded into a tool_request row — don't render standalone
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "agent_online" {
                                // Agent online announcements are internal coordination messages
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_update_guidance" {
                                // System guidance to Smith about reviewing Brown's task update — internal only
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_acknowledged" {
                                TaskAcknowledgedBanner(
                                    title: message.content,
                                    timestamp: message.timestamp
                                )
                                    .id(message.id)
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_continuing" {
                                TaskContinuingBanner(
                                    title: message.content,
                                    timestamp: message.timestamp
                                )
                                    .id(message.id)
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_complete" {
                                TaskReadyForReviewBanner(
                                    taskTitle: message.stringMetadata("taskTitle") ?? "",
                                    content: message.content,
                                    senderName: message.sender.displayName,
                                    recipientName: message.recipient?.displayName,
                                    timestamp: message.timestamp
                                )
                                    .id(message.id)
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "changes_requested" {
                                ChangesRequestedBanner(
                                    taskTitle: message.stringMetadata("taskTitle") ?? "",
                                    content: message.content,
                                    senderName: message.sender.displayName,
                                    recipientName: message.recipient?.displayName,
                                    timestamp: message.timestamp
                                )
                                    .id(message.id)
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_created" {
                                TaskCreatedBanner(
                                    title: message.content,
                                    description: message.stringMetadata("taskDescription"),
                                    timestamp: message.timestamp,
                                    contextMemories: message.stringMetadata("contextMemories"),
                                    contextPriorTasks: message.stringMetadata("contextPriorTasks"),
                                    memoryCount: message.intMetadata("contextMemoryCount") ?? 0,
                                    priorTaskCount: message.intMetadata("contextPriorTaskCount") ?? 0
                                )
                                    .id(message.id)
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_update" {
                                TaskUpdateBanner(
                                    content: message.content,
                                    senderName: message.sender.displayName,
                                    recipientName: message.recipient?.displayName,
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
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "task_summarized" {
                                TaskSummarizedBanner(
                                    taskTitle: message.stringMetadata("taskTitle") ?? "task",
                                    latencyMs: message.intMetadata("latencyMs") ?? 0,
                                    summary: message.content,
                                    timestamp: message.timestamp
                                )
                                    .id(message.id)
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "memory_saved" {
                                let isConsolidated = message.boolMetadata("consolidated") ?? false
                                MemoryBanner(
                                    kind: isConsolidated ? .consolidated : .saved,
                                    summary: message.content,
                                    detail: message.stringMetadata("memoryContent"),
                                    tags: message.stringMetadata("memoryTags"),
                                    source: message.stringMetadata("memorySource"),
                                    timestamp: message.timestamp
                                )
                                    .id(message.id)
                            } else if case .string(let kind) = message.metadata?["messageKind"], kind == "memory_searched" {
                                MemoryBanner(
                                    kind: .searched,
                                    summary: message.stringMetadata("searchQuery") ?? message.content,
                                    detail: nil,
                                    tags: nil,
                                    source: nil,
                                    timestamp: message.timestamp,
                                    memoryCount: message.intMetadata("memoryCount") ?? 0,
                                    taskCount: message.intMetadata("taskCount") ?? 0,
                                    memoryResults: message.stringMetadata("memoryResults"),
                                    taskResults: message.stringMetadata("taskResults")
                                )
                                    .id(message.id)
                            } else {
                                MessageRow(
                                    message: message,
                                    securityReviewMessage: message.stringMetadata("requestID").flatMap { reviewLookup[$0] },
                                    toolOutputMessage: message.stringMetadata("requestID").flatMap { outputLookup[$0] },
                                    selectedImageAttachment: $selectedImageAttachment
                                )
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
    private func shouldSuppress(_ message: ChannelMessage, toolRequestIDs: Set<String>) -> Bool {
        guard let reqID = message.stringMetadata("requestID") else { return false }
        let isFollowUp = message.metadata?["securityDisposition"] != nil
            || message.stringMetadata("messageKind") == "tool_output"
        guard isFollowUp else { return false }
        // Only suppress if the parent tool_request exists in the messages array
        return toolRequestIDs.contains(reqID)
    }
}

private struct MessageRow: View {
    let message: ChannelMessage
    /// Pre-looked-up security review for this message's requestID (nil if none).
    let securityReviewMessage: ChannelMessage?
    /// Pre-looked-up tool output for this message's requestID (nil if none).
    let toolOutputMessage: ChannelMessage?
    @Binding var selectedImageAttachment: Attachment?

    @State private var isExpanded = false
    @State private var isHovering = false

    /// Image tier for this message's attachments — user messages get small, others get medium.
    private var attachmentTier: ImageCache.Tier {
        message.sender == .user ? .small : .medium
    }

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

    /// True when Smith sends a private message to Brown.
    private var isSmithToBrown: Bool {
        guard case .agent(.smith) = message.sender else { return false }
        guard case .agent(.brown) = message.recipient else { return false }
        return true
    }

    /// True for any message sent by Brown (public or private).
    private var isBrownMessage: Bool {
        guard case .agent(.brown) = message.sender else { return false }
        return true
    }

    /// True for any message sent by the Summarizer agent.
    private var isSummarizerMessage: Bool {
        guard case .agent(.summarizer) = message.sender else { return false }
        return true
    }

    /// Default max visible lines for this message type. Nil means show all.
    private var defaultMaxLines: Int? {
        if isSummarizerMessage { return 2 }
        if isSmithToBrown || isBrownMessage { return 5 }
        return nil
    }

    // MARK: - Tool request grouping

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

    /// Human-readable tooltip text describing what the safety monitor determined.
    private var dispositionTooltipText: String? {
        guard let review = securityReviewMessage,
              case .string(let d) = review.metadata?["securityDisposition"] else { return nil }
        switch d {
        case "approved": return "Safety: Approved"
        case "autoApproved": return "Safety: Auto-approved (identical retry)"
        case "warning": return "Safety: Warning"
        case "denied": return "Safety: Denied"
        case "abort": return "Safety: Abort triggered"
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

                Text(sharedTimestampFormatter.string(from: message.timestamp))
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
                MarkdownText(content: message.content, baseFont: AppFonts.channelBody)
                    .foregroundStyle(securityReviewColor)
            } else if let maxLines = defaultMaxLines {
                collapsibleMessageBody(maxLines: maxLines)
            } else {
                MarkdownText(content: message.content, baseFont: AppFonts.channelBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.attachments.isEmpty {
                ForEach(message.attachments) { attachment in
                    AttachmentView(
                        attachment: attachment,
                        tier: attachmentTier,
                        onTapImage: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedImageAttachment = attachment
                            }
                        }
                    )
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
        .contentShape(Rectangle())
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

    // MARK: - Tool path extraction

    /// Keys that contain file paths, in priority order.
    private static let pathKeys = ["file_path", "path"]

    /// Extracts the primary file path from the tool call's params metadata, if any.
    /// Returns nil for tools that don't have path arguments or if params can't be parsed.
    private var toolFilePath: String? {
        guard let paramsJSON = message.stringMetadata("params"),
              let data = paramsJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            return nil
        }
        for key in Self.pathKeys {
            if case .string(let path) = dict[key], path.contains("/") {
                return path
            }
        }
        return nil
    }

    /// The tool call summary text with the primary path removed (for display alongside ToolPathText).
    /// Returns nil if no path was extracted.
    private func remainderWithoutPath(_ displayText: String, path: String) -> String {
        let toolName = message.stringMetadata("tool") ?? displayText.prefix(while: { $0 != ":" }).description
        var text = displayText
        // Remove "toolName: " prefix
        if text.hasPrefix(toolName) {
            text = String(text.dropFirst(toolName.count))
            if text.hasPrefix(": ") { text = String(text.dropFirst(2)) }
        }
        // Remove the path from the remaining text
        text = text.replacingOccurrences(of: path, with: "")
        // Clean up separators left behind (e.g. ", , " or leading ", ")
        text = text.replacingOccurrences(of: ", ,", with: ",")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        return text
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
        // Line 1: "file_write /dir/path/filename ⚡1/3 (show content) (show more) ✅"
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
            if let content = message.stringMetadata("fileWriteContent"), !content.isEmpty {
                Text(isExpanded ? "(hide content)" : "(show content)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            if isExpanded {
                Text("(show less)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else if toolOutputHasMore {
                Text("(show more)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            if let indicator = dispositionIndicator {
                if let tooltip = dispositionTooltipText {
                    Text(indicator).hoverTooltip(tooltip)
                } else {
                    Text(indicator)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }

        // Disposition comment (for WARN/UNSAFE/ABORT)
        if let comment = dispositionComment {
            MarkdownText(content: comment, baseFont: AppFonts.channelBody.italic())
                .foregroundStyle(dispositionCommentColor)
                .padding(.leading, 12)
        }

        // Inline diff: old file content → new file content.
        if let newContent = message.stringMetadata("fileWriteContent") {
            let oldContent = message.stringMetadata("fileWriteOldContent") ?? ""
            DiffView(oldContent: oldContent, newContent: newContent)
        }

        // Expanded content (raw new content, shown when user clicks "(show content)")
        if isExpanded, let content = message.stringMetadata("fileWriteContent") {
            Text(content)
                .font(AppFonts.channelBody.monospaced())
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }

        // Tool output: first line always shown (selectable); full content when expanded
        if let output = toolOutputMessage {
            if isExpanded {
                Text(output.content)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                let firstLine = output.content.components(separatedBy: .newlines).first ?? output.content
                Text(firstLine)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: generic tool display

    /// Whether this tool call was part of a parallel batch.
    private var parallelBadge: String? {
        guard case .int(let count) = message.metadata?["parallelCount"], count > 1,
              case .int(let index) = message.metadata?["parallelIndex"] else { return nil }
        return "\(index + 1)/\(count)"
    }

    /// Whether the tool output has more content than the first line.
    private var toolOutputHasMore: Bool {
        guard let output = toolOutputMessage else { return false }
        // file_read always hides its content by default, so any non-empty output
        // means there is "more" to reveal.
        if isFileRead { return !output.content.isEmpty }
        return output.content.contains(where: \.isNewline)
            || output.content.count > Self.outputTruncationLimit
    }

    /// Whether this tool call is `file_read` — its output is raw file content that
    /// should stay collapsed by default.
    private var isFileRead: Bool {
        message.stringMetadata("tool") == "file_read"
    }

    /// Whether a `file_edit` tool call failed. A successful edit always returns a
    /// "Successfully replaced …" message; anything else (Error:, BLOCKED:, Tool error:,
    /// etc.) is a failure. Pending calls (no output yet) return false so the optimistic
    /// diff is still shown while the call is in flight.
    private var fileEditFailed: Bool {
        guard let output = toolOutputMessage else { return false }
        let content = output.content.trimmingCharacters(in: .whitespaces)
        return !content.hasPrefix("Successfully")
    }

    /// Handles a tap on a tool call's file path. If the path exists, opens files via
    /// the default app and reveals directories in Finder. If the path doesn't exist
    /// (e.g., already deleted, or a path the tool couldn't resolve), falls through to
    /// toggling the row's expand state so the tap still does something useful.
    private func openFileOrFallback(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            isExpanded.toggle()
            return
        }
        if isDir.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var genericToolRequestBody: some View {
        // Line 1: "[bash] pwd (more) ✅" — tool name as chip, rest in secondary
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            let displayText = isExpanded ? message.content : toolCallDisplayText
            let toolName = message.stringMetadata("tool") ?? displayText.prefix(while: { $0 != ":" }).description
            ToolNameChip(name: toolName)
            if let path = toolFilePath {
                // Show path with highlighted filename, then remaining args.
                // Tap on the path opens the file (or reveals a directory) in Finder /
                // the default app — the inner gesture wins over the row's expand-toggle,
                // so clicking the filename doesn't accidentally collapse the row. If the
                // path doesn't exist, fall through to the expand-toggle behavior.
                ToolPathText(path: path)
                    .onTapGesture { openFileOrFallback(path: path) }
                let extra = remainderWithoutPath(displayText, path: path)
                if !extra.isEmpty {
                    Text(extra)
                        .font(AppFonts.channelBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                }
            } else {
                let remainder = displayText.hasPrefix(toolName) ? String(displayText.dropFirst(toolName.count)) : ": \(displayText)"
                let cleanRemainder = remainder.hasPrefix(": ") ? String(remainder.dropFirst(2)) : remainder
                Text(cleanRemainder)
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 1)
            }
            if let badge = parallelBadge {
                Text("⚡\(badge)")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.cyan.opacity(0.15))
                    .clipShape(Capsule())
            }
            if isExpanded {
                Text("(show less)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else if toolOutputHasMore {
                Text("(show more)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            if let indicator = dispositionIndicator {
                if let tooltip = dispositionTooltipText {
                    Text(indicator).hoverTooltip(tooltip)
                } else {
                    Text(indicator)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }

        // Disposition comment (for WARN/UNSAFE/ABORT) — always shown in full
        if let comment = dispositionComment {
            MarkdownText(content: comment, baseFont: AppFonts.channelBody.italic())
                .foregroundStyle(dispositionCommentColor)
                .padding(.leading, 12)
        }

        // file_edit inline diff — parse old_string / new_string from params.
        // Suppress the diff if the edit failed (e.g., `old_string` not found) so the
        // UI doesn't imply a change was applied when it wasn't. The error line from the
        // tool output is still shown below.
        if message.stringMetadata("tool") == "file_edit",
           !fileEditFailed,
           let (oldString, newString) = Self.fileEditStrings(from: message) {
            DiffView(oldContent: oldString, newContent: newString)
        }

        // Tool output: first line always shown (selectable); full content when expanded.
        // Exception: file_read hides its output entirely when collapsed, since the "first line"
        // is raw file data (typically "     1  ...") that clutters the channel.
        if let output = toolOutputMessage {
            if isExpanded {
                let fullText: String = {
                    if case .string(let expanded) = output.metadata?["expandedContent"] {
                        return expanded
                    }
                    return output.content
                }()
                Text(fullText)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if !isFileRead {
                let firstLine = output.content.components(separatedBy: .newlines).first ?? output.content
                Text(firstLine)
                    .font(AppFonts.channelBody.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .textSelection(.enabled)
            }
        }
    }

    /// Extracts (old_string, new_string) from a `file_edit` tool_request's params metadata.
    private static func fileEditStrings(from message: ChannelMessage) -> (String, String)? {
        guard let paramsJSON = message.stringMetadata("params"),
              let data = paramsJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            return nil
        }
        guard case .string(let oldString) = dict["old_string"],
              case .string(let newString) = dict["new_string"] else {
            return nil
        }
        return (oldString, newString)
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

    // MARK: - Collapsible message body

    /// Renders a message body with a default line limit and inline "(show more)".
    /// Summarizer messages indent from the 2nd line onwards.
    @ViewBuilder
    private func collapsibleMessageBody(maxLines: Int) -> some View {
        let lines = message.content.components(separatedBy: "\n")
        let needsTruncation = lines.count > maxLines

        if isExpanded || !needsTruncation {
            VStack(alignment: .leading, spacing: 1) {
                // For summarizer: indent all lines after the first
                if isSummarizerMessage {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        MarkdownText(content: line, baseFont: AppFonts.channelBody)
                            .padding(.leading, index > 0 ? 12 : 0)
                    }
                } else {
                    MarkdownText(content: message.content, baseFont: AppFonts.channelBody)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if needsTruncation {
                Text("(show less)")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(.leading, isSummarizerMessage ? 12 : 0)
                    .onTapGesture { isExpanded = false }
            }
        } else {
            let visibleLines = Array(lines.prefix(maxLines))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(visibleLines.dropLast().enumerated()), id: \.offset) { index, line in
                    MarkdownText(content: line, baseFont: AppFonts.channelBody)
                        .padding(.leading, isSummarizerMessage && index > 0 ? 12 : 0)
                }
                // Last visible line gets inline "(show more)"
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(visibleLines.last ?? "")
                        .font(AppFonts.channelBody)
                        .lineLimit(1)
                    Text(" (show more)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .padding(.leading, isSummarizerMessage && maxLines > 1 ? 12 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded = true }
        }
    }
}

// MARK: - ChannelMessage helper

private extension ChannelMessage {
    func stringMetadata(_ key: String) -> String? {
        if case .string(let value) = metadata?[key] { return value }
        return nil
    }

    func intMetadata(_ key: String) -> Int? {
        if case .int(let value) = metadata?[key] { return value }
        return nil
    }

    func doubleMetadata(_ key: String) -> Double? {
        switch metadata?[key] {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    func boolMetadata(_ key: String) -> Bool? {
        if case .bool(let value) = metadata?[key] { return value }
        return nil
    }
}

/// Visually distinct banner announcing a newly created task in the channel log.
private struct TaskCreatedBanner: View {
    let title: String
    let description: String?
    let timestamp: Date
    let contextMemories: String?
    let contextPriorTasks: String?
    let memoryCount: Int
    let priorTaskCount: Int

    @State private var isContextExpanded = false

    private let accentColor = AppColors.taskCreatedAccent
    private var hasContext: Bool { memoryCount > 0 || priorTaskCount > 0 }

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

                Text(sharedTimestampFormatter.string(from: timestamp))
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
                .padding(.bottom, description != nil || hasContext ? 2 : 6)

            if let description {
                MarkdownText(content: description, baseFont: AppFonts.channelBody.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, hasContext ? 2 : 6)
            }

            // Semantic context retrieved at task creation
            if hasContext {
                Divider().opacity(0.3).padding(.horizontal, 10)

                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)

                    let parts = [
                        memoryCount > 0
                            ? "\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")"
                            : nil,
                        priorTaskCount > 0
                            ? "\(priorTaskCount) prior task\(priorTaskCount == 1 ? "" : "s")"
                            : nil
                    ].compactMap { $0 }

                    Text("Context: \(parts.joined(separator: ", "))")
                        .font(AppFonts.channelBody)
                        .foregroundStyle(.purple.opacity(0.8))

                    Text(isContextExpanded ? "(hide)" : "(show)")
                        .font(.caption)
                        .foregroundStyle(.blue)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { isContextExpanded.toggle() }

                if isContextExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        if let contextMemories {
                            Text("Memories")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            let memoryEntries = parseContextEntries(contextMemories)
                            ForEach(Array(memoryEntries.enumerated()), id: \.offset) { idx, entry in
                                if idx > 0 {
                                    Divider().opacity(0.4)
                                }
                                Text(entry)
                                    .font(AppFonts.inspectorBody)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if let contextPriorTasks {
                            Text("Prior Tasks")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            let taskEntries = parseContextEntries(contextPriorTasks)
                            ForEach(Array(taskEntries.enumerated()), id: \.offset) { idx, entry in
                                if idx > 0 {
                                    Divider().opacity(0.4)
                                }
                                contextEntryView(entry)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Bottom rule
            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }

}

/// Splits a context metadata string into entries on the ASCII Record Separator (U+001E)
/// that `CreateTaskTool` and `SearchMemoryTool` write between items. Falls back to
/// splitting on newlines for backward compatibility with older persisted messages that
/// pre-date the separator change. Empty entries are dropped.
private func parseContextEntries(_ raw: String) -> [String] {
    let parts: [String]
    if raw.contains("\u{1E}") {
        parts = raw.components(separatedBy: "\u{1E}")
    } else {
        parts = raw.components(separatedBy: "\n")
    }
    return parts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Renders a single context entry as a bold header line followed by an optional body.
/// The header is the first line of the entry; everything after the first newline is body.
/// Used by both `TaskCreatedBanner` (prior tasks) and `MemoryBanner` (search results).
@ViewBuilder
private func contextEntryView(_ entry: String) -> some View {
    let split = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let header = split.first.map(String.init) ?? entry
    let body = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    VStack(alignment: .leading, spacing: 3) {
        Text(header)
            .font(AppFonts.inspectorBody.weight(.semibold))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
        if !body.isEmpty {
            Text(body)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

                Text(sharedTimestampFormatter.string(from: timestamp))
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

}

/// Banner for task_acknowledged messages in the channel log, styled like task created/completed.
private struct TaskAcknowledgedBanner: View {
    let title: String
    let timestamp: Date

    private let accentColor = AppColors.taskAcknowledgedAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accentColor)

                Text("Task Acknowledged")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                Spacer()

                Text(sharedTimestampFormatter.string(from: timestamp))
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
}

/// Banner for re-acknowledgement after a rejection (task status returns to running).
/// Visually distinct from `TaskAcknowledgedBanner` so it's obvious this isn't a fresh task.
private struct TaskContinuingBanner: View {
    let title: String
    let timestamp: Date

    private let accentColor = AppColors.taskAcknowledgedAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accentColor)

                Text("Continuing Task")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                Spacer()

                Text(sharedTimestampFormatter.string(from: timestamp))
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
}

/// Banner for Brown's `task_complete` submission — the task is awaiting Smith's review.
private struct TaskReadyForReviewBanner: View {
    let taskTitle: String
    let content: String
    let senderName: String
    let recipientName: String?
    let timestamp: Date

    @State private var isExpanded = false

    private let accentColor = AppColors.taskReadyForReviewAccent

    /// Splits the banner's `content` into (header, body). The header is everything
    /// before the first line that starts with "Result:"; the body is that line and
    /// everything after it. If no "Result:" marker is present, the full content is
    /// treated as the header and the body is nil.
    private var splitContent: (header: String, body: String?) {
        let lines = content.components(separatedBy: "\n")
        guard let resultIndex = lines.firstIndex(where: { $0.hasPrefix("Result:") }) else {
            return (content, nil)
        }
        let headerLines = lines[..<resultIndex]
        let bodyLines = lines[resultIndex...]
        let header = headerLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (header, body.isEmpty ? nil : body)
    }

    var body: some View {
        let parts = splitContent
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.up.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(accentColor)

                Text("Ready for Review")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                if let recipientName {
                    Text("\(senderName) \u{2192} \(recipientName)")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(sharedTimestampFormatter.string(from: timestamp))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if !taskTitle.isEmpty {
                Text(taskTitle)
                    .font(AppFonts.channelBody.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            }

            if !parts.header.isEmpty {
                MarkdownText(content: parts.header, baseFont: AppFonts.channelBody)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, parts.body == nil ? 6 : 2)
            }

            if let body = parts.body {
                Button(action: { isExpanded.toggle() }) {
                    Text(isExpanded ? "(hide result)" : "(show result)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, isExpanded ? 2 : 6)

                if isExpanded {
                    MarkdownText(content: body, baseFont: AppFonts.channelBody)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            }

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

/// Banner for Smith's rejection — feedback sent to Brown with requested changes.
private struct ChangesRequestedBanner: View {
    let taskTitle: String
    let content: String
    let senderName: String
    let recipientName: String?
    let timestamp: Date

    private let accentColor = AppColors.changesRequestedAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(accentColor)

                Text("Changes Requested")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                if let recipientName {
                    Text("\(senderName) \u{2192} \(recipientName)")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(sharedTimestampFormatter.string(from: timestamp))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if !taskTitle.isEmpty {
                Text(taskTitle)
                    .font(AppFonts.channelBody.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            }

            MarkdownText(content: content, baseFont: AppFonts.channelBody)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

/// Compact 1-liner for task summarization events.
private struct TaskSummarizedBanner: View {
    let taskTitle: String
    let latencyMs: Int
    let summary: String
    let timestamp: Date

    /// Truncate long task titles so the banner stays one line.
    private static let maxTitleLength = 60

    @State private var isExpanded = false

    private var displayTitle: String {
        if taskTitle.count <= Self.maxTitleLength { return taskTitle }
        return String(taskTitle.prefix(Self.maxTitleLength)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("Summarized task '\(displayTitle)' in \(latencyMs)ms")
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if isExpanded {
                    Text("(show less)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Text("(show more)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                Spacer()

                Text(sharedTimestampFormatter.string(from: timestamp))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                MarkdownText(content: summary, baseFont: AppFonts.channelBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

/// Small banner for task_update messages in the channel log.
private struct TaskUpdateBanner: View {
    let content: String
    let senderName: String
    let recipientName: String?
    let timestamp: Date

    private let accentColor = AppColors.taskUpdateAccent

    var body: some View {
        VStack(spacing: 0) {
            accentColor.frame(height: 1).opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(accentColor)

                Text("Task Update")
                    .font(AppFonts.channelSender)
                    .foregroundStyle(accentColor)

                if let recipientName {
                    Text("\(senderName) \u{2192} \(recipientName)")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(sharedTimestampFormatter.string(from: timestamp))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            MarkdownText(content: content, baseFont: AppFonts.channelBody)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            accentColor.frame(height: 1).opacity(0.4)
        }
        .background(accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }
}

/// Green mini-banner for memory save/search events in the channel log.
private struct MemoryBanner: View {
    enum Kind { case saved, consolidated, searched }

    let kind: Kind
    let summary: String
    let detail: String?
    let tags: String?
    let source: String?
    let timestamp: Date
    var memoryCount: Int = 0
    var taskCount: Int = 0
    /// For `.searched` only — formatted memory result entries joined by `\u{1E}`.
    var memoryResults: String? = nil
    /// For `.searched` only — formatted task summary result entries joined by `\u{1E}`.
    var taskResults: String? = nil

    @State private var isExpanded = false

    private let accentColor: Color = .green

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accentColor.frame(height: 1).opacity(0.3)

            Button(action: {
                guard hasExpandableContent else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }, label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 10))
                        .foregroundStyle(accentColor)

                    Text(headerText)
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(accentColor)

                    Text(summaryPreview)
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if hasExpandableContent {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }

                    Text(sharedTimestampFormatter.string(from: timestamp))
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            })
            .buttonStyle(.plain)

            if isExpanded {
                expandedBody
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }

            accentColor.frame(height: 1).opacity(0.3)
        }
        .background(accentColor.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(.vertical, 1)
    }

    private var headerText: String {
        switch kind {
        case .saved: return "Memory Saved"
        case .consolidated: return "Memory Consolidated"
        case .searched:
            if memoryCount == 0 && taskCount == 0 {
                return "Memory Search — no results"
            }
            var parts: [String] = []
            if memoryCount > 0 { parts.append("\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")") }
            if taskCount > 0 { parts.append("\(taskCount) task\(taskCount == 1 ? "" : "s")") }
            return "Memory Search — \(parts.joined(separator: ", "))"
        }
    }

    private var iconName: String {
        switch kind {
        case .saved: return "brain.head.profile"
        case .consolidated: return "arrow.triangle.merge"
        case .searched: return "magnifyingglass"
        }
    }

    /// Single-line preview shown next to the header. Returns the full summary so SwiftUI's
    /// `.lineLimit(1)` can truncate to fit the available width — no arbitrary char cap.
    private var summaryPreview: String {
        summary
    }

    private var hasExpandableContent: Bool {
        switch kind {
        case .saved, .consolidated:
            return detail != nil && !(detail ?? "").isEmpty
        case .searched:
            let hasMemories = !(memoryResults?.isEmpty ?? true)
            let hasTasks = !(taskResults?.isEmpty ?? true)
            return hasMemories || hasTasks
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        switch kind {
        case .saved, .consolidated:
            if let detail, !detail.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail)
                        .font(AppFonts.channelBody)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    if let tags, !tags.isEmpty {
                        Text("Tags: \(tags)")
                            .font(AppFonts.channelTimestamp)
                            .foregroundStyle(.secondary)
                    }
                    if let source, !source.isEmpty {
                        Text("Source: \(source)")
                            .font(AppFonts.channelTimestamp)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .searched:
            VStack(alignment: .leading, spacing: 10) {
                if let memoryResults, !memoryResults.isEmpty {
                    Text("Memories")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    let entries = parseContextEntries(memoryResults)
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                        if idx > 0 { Divider().opacity(0.4) }
                        contextEntryView(entry)
                    }
                }
                if let taskResults, !taskResults.isEmpty {
                    Text("Prior Tasks")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    let entries = parseContextEntries(taskResults)
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                        if idx > 0 { Divider().opacity(0.4) }
                        contextEntryView(entry)
                    }
                }
            }
        }
    }

}

/// Displays an attachment inline: images as cached thumbnails, other files as badges.
/// Uses `ImageCache` for efficient tiered rendering. Tapping an image invokes `onTapImage`.
private struct AttachmentView: View {
    let attachment: Attachment
    let tier: ImageCache.Tier
    var onTapImage: (() -> Void)?

    @State private var loadedImage: NSImage?

    var body: some View {
        if attachment.isImage {
            imageView
                .task(id: attachment.id) {
                    loadedImage = await ImageCache.shared.image(for: attachment, tier: tier)
                }
        } else {
            fileBadge
        }
    }

    private var imageView: some View {
        Group {
            if let nsImage = loadedImage
                ?? ImageCache.shared.cachedImage(for: attachment, tier: tier) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: tier == .small ? 200 : 400,
                           maxHeight: tier == .small ? 150 : 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { onTapImage?() }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.set() }
                        else { NSCursor.arrow.set() }
                    }
            } else {
                ProgressView()
                    .frame(width: 60, height: 60)
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

/// Full-screen overlay that displays an image at its original resolution.
/// Dismisses on backdrop click or the close button. Escape is handled by the parent
/// view via a @FocusState so it intercepts before MainView's stop-agents handler.
struct ImageLightbox: View {
    let attachment: Attachment
    let onDismiss: () -> Void

    @State private var fullImage: NSImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            if let nsImage = fullImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(40)
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Image could not be loaded")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
                Text(attachment.filename)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 16)
            }
        }
        .transition(.opacity)
        .task {
            let image = await ImageCache.shared.image(for: attachment, tier: .full)
            if let image {
                fullImage = image
            } else {
                loadFailed = true
            }
        }
    }
}

/// Renders a `file_write` path with colored directory components and a clickable filename.
/// If the path traversed a symlink (detected by checking the resolved path), shows the
/// symlink destination as a secondary label.
/// Renders a tool name as a styled chip (blue text, light background, subtle border).
private struct ToolNameChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(AppFonts.channelBody)
            .foregroundStyle(.blue)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.blue.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.blue.opacity(0.4), lineWidth: 1.0)
            )
    }
}

/// Renders a file path with the directory dimmed and the filename highlighted in bold cyan.
private struct ToolPathText: View {
    let path: String

    private var directory: String {
        guard !path.isEmpty else { return "" }
        let dir = (path as NSString).deletingLastPathComponent
        return dir.hasSuffix("/") ? dir : dir + "/"
    }

    private var filename: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(directory)
                .font(AppFonts.channelBody)
                .foregroundStyle(.secondary.opacity(0.7))
                .lineLimit(1)
            Text(filename)
                .font(AppFonts.channelBody.bold())
                .foregroundStyle(.cyan)
                .lineLimit(1)
        }
    }
}

private struct FileWritePathView: View {
    let path: String

    private var url: URL { URL(fileURLWithPath: path) }

    /// If the path is a symlink (or contains symlinks), returns the resolved destination.
    private var symlinkDestination: String? {
        guard !path.isEmpty else { return nil }
        let resolved = url.resolvingSymlinksInPath().path
        let standardized = url.standardized.path
        return resolved != standardized ? resolved : nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ToolNameChip(name: "file_write")
            ToolPathText(path: path)
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

// MARK: - Hover Tooltip

/// A lightweight tooltip that appears immediately on hover, positioned above the anchor view.
/// Avoids the long delay of the system `.help()` modifier.
private struct HoverTooltip: ViewModifier {
    let text: String

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isHovering {
                    Text(text)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        .fixedSize()
                        .offset(y: -26)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                }
            }
            .onHover { isHovering = $0 }
    }
}

private extension View {
    func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltip(text: text))
    }
}
