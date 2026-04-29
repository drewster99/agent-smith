import SwiftUI
import AgentSmithKit

/// Single-view per ForEach iteration in the sidebar task list — bundles the row's
/// click button with its trailing divider so the ForEach yields one view per task.
struct TaskListRow: View {
    let task: AgentTask
    let style: TaskRowStyle
    let viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskRowButton(task: task, style: style, viewModel: viewModel)
            Divider()
        }
    }
}
