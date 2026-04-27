import SwiftUI
import AppKit
import AgentSmithKit

/// Writes the task's UUID string to the system pasteboard so the user can paste it into
/// a tool call, log search, or external note. Used by every task-row context menu.
private func copyTaskIDToPasteboard(_ id: UUID) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(id.uuidString, forType: .string)
}

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
                        openWindow(value: TaskDetailTarget(sessionID: viewModel.session.id, taskID: task.id))
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
                            openWindow(value: TaskDetailTarget(sessionID: viewModel.session.id, taskID: task.id))
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
                            openWindow(value: TaskDetailTarget(sessionID: viewModel.session.id, taskID: task.id))
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

/// Future-fire-time label for a scheduled task. Today → bare time ("9:00 PM");
/// tomorrow → "Tomorrow 9:00 AM"; within a week → weekday + time; further out →
/// month/day + time. Shared by the task list rows and the channel log's New Task
/// banner so the formatting stays consistent.
func formatScheduledTime(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) {
        return time
    }
    if calendar.isDateInTomorrow(date) {
        return "Tomorrow \(time)"
    }
    let now = Date()
    if let weekFromNow = calendar.date(byAdding: .day, value: 7, to: now), date < weekFromNow {
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        return "\(weekday) \(time)"
    }
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    return "\(day) \(time)"
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
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(TaskStatusBadge.color(for: task.status).opacity(0.2)))
                                .foregroundStyle(TaskStatusBadge.color(for: task.status))

                            ScheduledRunsIndicator(task: task, viewModel: viewModel)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: { copyTaskIDToPasteboard(task.id) }, label: {
                Label("Copy Task ID", systemImage: "doc.on.doc")
            })
            Divider()
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

            case .pending, .paused, .interrupted, .scheduled:
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
            Button(action: { copyTaskIDToPasteboard(task.id) }, label: {
                Label("Copy Task ID", systemImage: "doc.on.doc")
            })
            Divider()
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
            Button(action: { copyTaskIDToPasteboard(task.id) }, label: {
                Label("Copy Task ID", systemImage: "doc.on.doc")
            })
            Divider()
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

// MARK: - Scheduled-runs indicator

/// Compact pill on a task row showing the next pending wake's fire time. Falls back to the
/// task's `updatedAt` timestamp when the task has no pending wakes (so completed tasks still
/// show *something*). When pending wakes exist, the pill is a button that pops over a list
/// of every upcoming run for the task — useful when a recurring schedule has many pending
/// occurrences queued.
private struct ScheduledRunsIndicator: View {
    let task: AgentTask
    let viewModel: AppViewModel

    @State private var showingPopover = false

    var body: some View {
        let now = Date()
        let pendingWakes = viewModel.activeTimers
            .filter { $0.taskID == task.id && $0.wakeAt > now }
            .sorted { $0.wakeAt < $1.wakeAt }

        if let nextWake = pendingWakes.first {
            Button(action: { showingPopover.toggle() }, label: {
                HStack(spacing: 3) {
                    Image(systemName: nextWake.recurrence == nil ? "clock" : "arrow.triangle.2.circlepath")
                        .imageScale(.small)
                    Text("Next: \(formatScheduledTime(nextWake.wakeAt))")
                    if pendingWakes.count > 1 {
                        Text("+\(pendingWakes.count - 1)")
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(TaskStatusBadge.color(for: .scheduled).opacity(0.25)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(TaskStatusBadge.color(for: .scheduled))
                .fixedSize()
            })
            .buttonStyle(.plain)
            .help(pendingWakes.count == 1 ? "Show scheduled run" : "Show \(pendingWakes.count) scheduled runs")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                ScheduledRunsPopover(task: task, wakes: pendingWakes, viewModel: viewModel)
            }
        } else {
            Text(taskTimestamp(task.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }
}

/// Popover content listing every pending wake for a task. Each row shows the absolute
/// fire time, a relative "in N min/h" countdown, the recurrence pattern (if any), and a
/// cancel button — clicking cancel removes the wake via `AppViewModel.cancelTimer(id:)`,
/// which also refreshes `activeTimers` so the popover (and parent row) update in place.
private struct ScheduledRunsPopover: View {
    let task: AgentTask
    let wakes: [ScheduledWake]
    let viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scheduled runs")
                    .font(.headline)
                Spacer()
                Text("\(wakes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(wakes, id: \.id) { wake in
                        ScheduledRunsPopoverRow(wake: wake, onCancel: {
                            Task { await viewModel.cancelTimer(id: wake.id) }
                        })
                        Divider()
                    }
                }
            }
            .frame(minWidth: 320, maxWidth: 400, minHeight: 80, maxHeight: 360)
        }
    }
}

private struct ScheduledRunsPopoverRow: View {
    let wake: ScheduledWake
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: wake.recurrence == nil ? "clock" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(formatScheduledTime(wake.wakeAt))
                    .font(.callout)
                HStack(spacing: 8) {
                    Text(relativeCountdown(to: wake.wakeAt))
                    if let recurrence = wake.recurrence {
                        Text("·")
                        Text(recurrence.displayDescription)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button(role: .destructive, action: onCancel, label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            })
            .buttonStyle(.plain)
            .help("Cancel this scheduled run")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func relativeCountdown(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval < 60 { return "in <1 min" }
        if interval < 3600 { return "in \(Int(interval / 60)) min" }
        if interval < 86400 { return String(format: "in %.1f h", interval / 3600) }
        return String(format: "in %.1f d", interval / 86400)
    }
}
