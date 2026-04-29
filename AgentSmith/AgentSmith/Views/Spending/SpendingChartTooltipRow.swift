import SwiftUI

/// One provider line inside the chart's hover tooltip — provider name on the left,
/// formatted cost on the right.
struct SpendingChartTooltipRow: View {
    let provider: String
    let costFormatted: String

    var body: some View {
        HStack(spacing: 4) {
            Text(provider)
                .font(.caption2)
            Spacer(minLength: 8)
            Text(costFormatted)
                .font(.caption2.monospacedDigit())
        }
    }
}
