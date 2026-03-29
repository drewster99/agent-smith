import SwiftUI
import UniformTypeIdentifiers
import AgentSmithKit

/// Text field with attachment support for sending messages to Smith.
struct UserInputView: View {
    @Binding var text: String
    var pendingAttachments: [Attachment]
    var isRunning: Bool
    var onSend: () -> Void
    var onAttach: ([URL]) -> Void
    var onRemoveAttachment: (UUID) -> Void
    var onHistoryUp: () -> Bool
    var onHistoryDown: () -> Bool
    var onPaste: () -> Bool

    @State private var showingFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            if !pendingAttachments.isEmpty {
                PendingAttachmentBar(
                    attachments: pendingAttachments,
                    onRemove: onRemoveAttachment
                )
                Divider()
            }

            HStack(spacing: 8) {
                Button {
                    showingFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .disabled(!isRunning)

                TextField(
                    isRunning ? "Message Agent Smith..." : "Press Start to begin messaging...",
                    text: $text
                )
                    .font(AppFonts.inputField)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(AppColors.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit {
                        if isRunning && hasContent {
                            onSend()
                        }
                    }
                    .onKeyPress(.upArrow) {
                        onHistoryUp() ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow) {
                        onHistoryDown() ? .handled : .ignored
                    }
                    .onKeyPress(characters: .init(charactersIn: "v"), phases: .down, action: { keyPress in
                        guard keyPress.modifiers == .command else { return .ignored }
                        // Only intercept if the clipboard has non-text content (images/files).
                        // Let normal text paste through to the TextField.
                        let pasteboard = NSPasteboard.general
                        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [
                            .urlReadingFileURLsOnly: true
                        ])
                        let hasImage = pasteboard.data(forType: .tiff) != nil
                        guard hasFiles || hasImage else { return .ignored }
                        return onPaste() ? .handled : .ignored
                    })

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasContent || !isRunning)
                .opacity(hasContent && isRunning ? 1.0 : 0.4)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(8)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                onAttach(urls)
            }
        }
    }

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }
}

/// Horizontal scrolling bar of pending attachments before sending.
private struct PendingAttachmentBar: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    PendingAttachmentChip(
                        attachment: attachment,
                        onRemove: { onRemove(attachment.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(AppColors.secondaryBackground.opacity(0.5))
    }
}

/// A single removable attachment chip in the pending bar.
/// Shows an aspect-fit thumbnail on a square matte for image attachments.
private struct PendingAttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if attachment.isImage, let nsImage = ImageCache.shared.image(for: attachment, tier: .chip) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
            }
            Text(attachment.filename)
                .font(.caption)
                .lineLimit(1)
            Text(attachment.formattedSize)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(Capsule())
    }

    private var iconName: String {
        if attachment.isPDF { return "doc.richtext" }
        if attachment.mimeType.hasPrefix("text/") { return "doc.text" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }
}
