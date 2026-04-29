import SwiftUI
import AgentSmithKit

/// Single-view per ForEach iteration in the scheduled-runs popover — bundles the wake
/// row with its trailing divider so the ForEach yields one view per wake.
struct ScheduledRunsPopoverItem: View {
    let wake: ScheduledWake
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScheduledRunsPopoverRow(wake: wake, onCancel: onCancel)
            Divider()
        }
    }
}
