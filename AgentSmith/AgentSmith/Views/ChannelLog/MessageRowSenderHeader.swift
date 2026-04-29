import SwiftUI
import AgentSmithKit

/// Top header for a `MessageRow`: sender name, optional private-recipient annotation,
/// optional timestamp, and an optional elapsed-time chip for tool-call rows.
struct MessageRowSenderHeader: View {
    let message: ChannelMessage
    let senderColor: Color
    let recipientColor: Color
    let hidesPrivateRecipientAnnotation: Bool
    let shouldShowTimestamp: Bool
    let isToolRequest: Bool
    let displayPrefs: TimestampPreferences
    let toolCallElapsedSeconds: TimeInterval?

    var body: some View {
        HStack(spacing: 6) {
            Text(message.sender.displayName)
                .font(AppFonts.channelSender)
                .foregroundStyle(senderColor)

            if message.isPrivate && !hidesPrivateRecipientAnnotation {
                Image(systemName: "lock.fill")
                    .font(AppFonts.metaIcon)
                    .foregroundStyle(.secondary)
                Text("\u{2192} \(message.recipient?.displayName ?? "private")")
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(recipientColor)
            }

            if shouldShowTimestamp {
                Text(sharedTimestampFormatter.string(from: message.timestamp))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }

            if isToolRequest, displayPrefs.elapsedTimeOnToolCalls,
               let elapsed = toolCallElapsedSeconds {
                Text(formatToolCallElapsed(elapsed))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
