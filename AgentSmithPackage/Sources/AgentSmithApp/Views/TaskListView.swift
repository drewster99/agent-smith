import SwiftUI
import AgentSmithKit

/// Displays tasks with status badges and assignee info.
struct TaskListView: View {
    var tasks: [AgentTask]

    var body: some View {
        if tasks.isEmpty {
            ContentUnavailableView(
                "No Tasks",
                systemImage: "checklist",
                description: Text("Tasks will appear here when Smith creates them.")
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tasks) { task in
                    TaskRow(task: task)
                    Divider()
                }
            }
        }
    }
}

private struct TaskRow: View {
    let task: AgentTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: TaskStatusBadge.icon(for: task.status))
                .foregroundStyle(TaskStatusBadge.color(for: task.status))
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(AppFonts.taskTitle)
                    .lineLimit(1)

                Text(task.description)
                    .font(AppFonts.taskDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(task.status.rawValue.capitalized)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(TaskStatusBadge.color(for: task.status).opacity(0.2))
                )
                .foregroundStyle(TaskStatusBadge.color(for: task.status))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
