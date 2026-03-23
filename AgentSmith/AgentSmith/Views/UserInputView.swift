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

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasContent || !isRunning)
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
private struct PendingAttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .foregroundStyle(.secondary)
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
}
