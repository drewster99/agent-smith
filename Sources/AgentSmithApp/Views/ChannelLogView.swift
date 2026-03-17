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
                        MessageRow(message: message)
                            .id(message.id)
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
}

private struct MessageRow: View {
    let message: ChannelMessage

    private var senderColor: Color {
        AppColors.color(for: message.sender)
    }

    private var isToolMessage: Bool {
        message.metadata?["tool"] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.sender.displayName)
                    .font(AppFonts.channelSender)
                    .foregroundStyle(senderColor)

                Text(message.timestamp, style: .time)
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }

            if isToolMessage {
                DisclosureGroup {
                    Text(message.content)
                        .font(AppFonts.channelBody)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } label: {
                    Text(toolSummary)
                        .font(AppFonts.channelBody)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(message.content)
                    .font(AppFonts.channelBody)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            // Display attachments
            if !message.attachments.isEmpty {
                ForEach(message.attachments) { attachment in
                    AttachmentView(attachment: attachment)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolSummary: String {
        if case .string(let toolName) = message.metadata?["tool"] {
            return "Tool call: \(toolName)"
        }
        return "Tool call"
    }
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
