import SwiftUI

/// Stepper controls for an agent's per-response tool-call cap and poll interval.
struct AgentConfigResponsivenessSection: View {
    @Binding var draftMaxToolCalls: Int
    @Binding var draftPollInterval: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Responsiveness")
                .font(AppFonts.inspectorLabel.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Max Tool Calls / Response")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                Stepper(
                    "\(draftMaxToolCalls)",
                    value: $draftMaxToolCalls,
                    in: 1...500,
                    step: 1
                )
                .labelsHidden()
                Text("\(draftMaxToolCalls)")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                Text("Poll Interval")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                Stepper(
                    "\(Int(draftPollInterval))s",
                    value: $draftPollInterval,
                    in: 1...300,
                    step: 1
                )
                .labelsHidden()
                Text("\(Int(draftPollInterval)) seconds")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
