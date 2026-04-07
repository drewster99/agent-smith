import SwiftUI
import AgentSmithKit

/// Sidebar task list with active tasks, an optional archived section, and a recently-deleted section.
struct TaskListView: View {
    let viewModel: AppViewModel

    @State private var showArchived = false
    @State private var showDeleted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let activeTasks = viewModel.tasks.filter { $0.disposition == .active }
        let archivedTasks = viewModel.tasks.filter { $0.disposition == .archived }
        let deletedTasks = viewModel.tasks.filter { $0.disposition == .recentlyDeleted }
        let errorBinding = Binding(
            get: { viewModel.taskActionError != nil },
            set: { if !$0 { viewModel.taskActionError = nil } }
        )

        Group {
        if activeTasks.isEmpty && archivedTasks.isEmpty && deletedTasks.isEmpty {
            ContentUnavailableView(
                "No Tasks",
                systemImage: "checklist",
                description: Text("Tasks will appear here when Smith creates them.")
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Active task rows
                ForEach(activeTasks) { task in
                    Button {
                        openWindow(value: task.id)
                    } label: {
                        ActiveTaskRow(task: task, viewModel: viewModel)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }

                // Bucket toggles
                if !archivedTasks.isEmpty || !deletedTasks.isEmpty {
                    HStack(spacing: 16) {
                        if !archivedTasks.isEmpty {
                            Button(action: { showArchived.toggle() }, label: {
                                Label(
                                    "Archived (\(archivedTasks.count))",
                                    systemImage: showArchived ? "archivebox.fill" : "archivebox"
                                )
                                .font(.caption)
                                .foregroundStyle(showArchived ? .primary : .secondary)
                            })
                            .buttonStyle(.plain)
                        }

                        if !deletedTasks.isEmpty {
                            Button(action: { showDeleted.toggle() }, label: {
                                Label(
                                    "Deleted (\(deletedTasks.count))",
                                    systemImage: showDeleted ? "trash.fill" : "trash"
                                )
                                .font(.caption)
                                .foregroundStyle(showDeleted ? .red : .secondary)
                            })
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                // Archived section
                if showArchived && !archivedTasks.isEmpty {
                    TaskSectionHeader(title: "Archived")
                    ForEach(archivedTasks) { task in
                        Button {
                            openWindow(value: task.id)
                        } label: {
                            ArchivedTaskRow(task: task, viewModel: viewModel)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }

                // Recently deleted section
                if showDeleted && !deletedTasks.isEmpty {
                    TaskSectionHeader(title: "Recently Deleted")
                    ForEach(deletedTasks) { task in
                        Button {
                            openWindow(value: task.id)
                        } label: {
                            DeletedTaskRow(task: task, viewModel: viewModel)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        } // end Group
        .alert(
            "Cannot Complete Action",
            isPresented: errorBinding,
            actions: { Button("OK") { viewModel.taskActionError = nil } },
            message: { Text(viewModel.taskActionError ?? "") }
        )
    }
}

// MARK: - Section header

private struct TaskSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
    }
}

// MARK: - Timestamp helper

private func taskTimestamp(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    } else if calendar.isDateInYesterday(date) {
        return "Yesterday"
    } else {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Active task row

private struct ActiveTaskRow: View {
    let task: AgentTask
    let viewModel: AppViewModel

    @State private var rotation: Double = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: TaskStatusBadge.icon(for: task.status))
                .foregroundStyle(TaskStatusBadge.color(for: task.status))
                .imageScale(.medium)
                .frame(width: 18)
                .padding(.top, 2)
                .rotationEffect(task.status == .running ? .degrees(rotation) : .zero)
                .task(id: task.status) {
                    guard task.status == .running else {
                        rotation = 0
                        return
                    }
                    while !Task.isCancelled {
                        withAnimation(.linear(duration: 3)) {
                            rotation += 360
                        }
                        try? await Task.sleep(for: .seconds(3))
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                // Title row — spans full width; running tasks get inline controls on the right.
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(AppFonts.taskTitle)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if task.status == .running {
                        HStack(spacing: 6) {
                            Button(action: { Task { await viewModel.pauseTask(id: task.id) } }, label: {
                                Image(systemName: "pause.fill")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                            })
                            .buttonStyle(.plain)
                            .help("Pause")

                            Button(action: { Task { await viewModel.stopTask(id: task.id) } }, label: {
                                Image(systemName: "stop.fill")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                            })
                            .buttonStyle(.plain)
                            .help("Stop")
                        }
                    }
                }

                // Description + status badge + timestamp on one line.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.description)
                        .font(AppFonts.taskDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    if task.status != .running {
                        HStack(spacing: 4) {
                            Text(task.status.rawValue.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(TaskStatusBadge.color(for: task.status).opacity(0.2)))
                                .foregroundStyle(TaskStatusBadge.color(for: task.status))

                            Text(taskTimestamp(task.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            switch task.status {
            case .completed:
                Button(action: { Task { await viewModel.runTaskAgain(task) } }, label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                })
                Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                    Label("Archive", systemImage: "archivebox")
                })
                Divider()
                Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                    Label("Delete", systemImage: "trash")
                })

            case .failed:
                Button(action: { Task { await viewModel.retryTask(task) } }, label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                })
                Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                    Label("Archive", systemImage: "archivebox")
                })
                Divider()
                Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                    Label("Delete", systemImage: "trash")
                })

            case .running:
                Button(action: { Task { await viewModel.pauseTask(id: task.id) } }, label: {
                    Label("Pause", systemImage: "pause.fill")
                })
                Button(action: { Task { await viewModel.stopTask(id: task.id) } }, label: {
                    Label("Stop", systemImage: "stop.fill")
                })
                Divider()
                Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                    Label("Archive", systemImage: "archivebox")
                })
                Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                    Label("Delete", systemImage: "trash")
                })

            case .awaitingReview:
                EmptyView()

            case .pending, .paused, .interrupted:
                Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                    Label("Archive", systemImage: "archivebox")
                })
                Divider()
                Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                    Label("Delete", systemImage: "trash")
                })
            }
        }
    }
}

// MARK: - Archived task row

private struct ArchivedTaskRow: View {
    let task: AgentTask
    let viewModel: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: TaskStatusBadge.icon(for: task.status))
                .foregroundStyle(TaskStatusBadge.color(for: task.status).opacity(0.5))
                .imageScale(.medium)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(AppFonts.taskTitle)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.description)
                        .font(AppFonts.taskDescription)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(taskTimestamp(task.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: { Task { await viewModel.unarchiveTask(id: task.id) } }, label: {
                Label("Unarchive", systemImage: "arrow.uturn.backward")
            })
            Divider()
            Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                Label("Delete", systemImage: "trash")
            })
        }
    }
}

// MARK: - Recently deleted task row

private struct DeletedTaskRow: View {
    let task: AgentTask
    let viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: TaskStatusBadge.icon(for: task.status))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .imageScale(.medium)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(AppFonts.taskTitle)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                    .strikethrough(true, color: .secondary)

                Text(task.description)
                    .font(AppFonts.taskDescription)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: { Task { await viewModel.undeleteTask(id: task.id) } }, label: {
                Label("Undelete", systemImage: "arrow.uturn.backward")
            })
            Divider()
            Button(role: .destructive, action: { Task { await viewModel.permanentlyDeleteTask(id: task.id) } }, label: {
                Label("Delete Permanently", systemImage: "trash.fill")
            })
        }
    }
}
