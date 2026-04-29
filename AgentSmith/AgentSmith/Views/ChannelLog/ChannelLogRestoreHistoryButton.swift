import SwiftUI

/// Pill button that prompts the user to load all persisted history into the channel log.
/// Only rendered while a persisted-but-unrestored history exists.
struct ChannelLogRestoreHistoryButton: View {
    let persistedHistoryCount: Int
    let onRestoreHistory: () -> Void

    var body: some View {
        Button(action: onRestoreHistory, label: {
            Text("Restore full history (\(persistedHistoryCount) messages)")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary)
                .clipShape(Capsule())
        })
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.bottom, 4)
    }
}
