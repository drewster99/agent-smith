import SwiftUI

/// One row in the Spending Dashboard's "Tool Calls" breakdown card.
struct SpendingToolCountRow: View {
    let toolName: String
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            Text(toolName)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .frame(width: 50, alignment: .trailing)
        }
    }
}
