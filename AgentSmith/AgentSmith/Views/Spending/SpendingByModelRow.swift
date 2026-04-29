import SwiftUI

/// One row in the Spending Dashboard's "By Model" breakdown card.
struct SpendingByModelRow: View {
    let modelName: String
    let costFormatted: String
    let callCount: Int

    var body: some View {
        HStack(spacing: 0) {
            Text(modelName)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(costFormatted)
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Text("\(callCount) calls")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }
}
