import SwiftUI
import AgentSmithKit

/// Expanded body for `SummarizerCard`: activity stats and recent summarization rows.
struct SummarizerCardExpandedSections: View {
    let summarizerMessages: [ChannelMessage]
    let summaryCount: Int
    let errorCount: Int

    private var hasActivity: Bool { !summarizerMessages.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasActivity {
                InspectorSection(title: "Activity") {
                    HStack(spacing: 12) {
                        Label("\(summaryCount) summarized", systemImage: "checkmark.circle.fill")
                            .font(AppFonts.inspectorBody)
                            .foregroundStyle(.green)
                        if errorCount > 0 {
                            Label("\(errorCount) failed", systemImage: "xmark.circle.fill")
                                .font(AppFonts.inspectorBody)
                                .foregroundStyle(.red)
                        }
                    }
                }

                InspectorSection(title: "Recent (\(summarizerMessages.count))") {
                    ForEach(Array(summarizerMessages.suffix(8).reversed()), id: \.id) { msg in
                        SummarizerActivityRow(message: msg)
                    }
                }
            } else {
                Text("No summarization activity yet.")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}
