import SwiftUI
import Charts
import AgentSmithKit
import SwiftLLMKit

/// Spending Dashboard — dedicated analytics window showing cost, token usage,
/// and tool statistics across configurable time ranges.
///
/// Built in sections:
///   1. Headline card — big cost number, delta vs prior period, quick stats
///   2. Cost over time chart (stacked by provider)
///   3. Breakdown panels (provider, agent, model, tools)
///   4. Task ledger (sortable table)
///
/// Opened via View → Spending Dashboard (⌘⇧D).
struct SpendingDashboardView: View {
    @Bindable var shared: SharedAppState

    // MARK: - State

    @State private var selectedRange: TimeRange = .week
    @State private var allRecords: [UsageRecord] = []
    /// The date bucket currently hovered in the cost-over-time chart (nil = none).
    @State private var chartHoveredDate: Date?
    /// Task selected for the detail sheet (nil = no sheet shown).
    @State private var selectedTaskID: UUID?
    /// Task row currently hovered for visual highlight.
    @State private var hoveredTaskID: UUID?
    /// Snapshot of pricing data, captured on load so the aggregator closure doesn't
    /// need to cross actor boundaries.
    @State private var pricingSnapshot: [String: ModelPricing] = [:]
    /// Provider ID → display name lookup, captured on load.
    @State private var providerNames: [String: String] = [:]
    @State private var isLoading = true

    // MARK: - Cached derived state (recomputed on load and range change)

    /// Filtered to the selected time range. Recomputed via `recomputeDerivedState()`.
    @State private var filteredRecords: [UsageRecord] = []
    /// Records from the equivalent prior period (for delta comparison).
    @State private var priorRecords: [UsageRecord] = []
    /// Aggregated summary of `filteredRecords`.
    @State private var currentSummary: UsageSummary = .empty()
    /// Aggregated summary of `priorRecords`.
    @State private var priorSummary: UsageSummary = .empty()

    // MARK: - Time range

    enum TimeRange: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "Week"
        case month = "Month"
        case all = "All"

        var id: String { rawValue }

        /// Returns the (start, end) date interval for this range, and the equivalent
        /// prior period for delta calculation.
        func dateInterval(calendar: Calendar = .current) -> (current: (start: Date, end: Date), prior: (start: Date, end: Date)) {
            let now = Date()
            let start: Date
            let priorStart: Date
            let priorEnd: Date

            switch self {
            case .today:
                start = calendar.startOfDay(for: now)
                priorStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start
                priorEnd = start
            case .week:
                start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
                priorStart = calendar.date(byAdding: .day, value: -7, to: start) ?? start
                priorEnd = start
            case .month:
                start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
                priorStart = calendar.date(byAdding: .month, value: -1, to: start) ?? start
                priorEnd = start
            case .all:
                start = .distantPast
                priorStart = .distantPast
                priorEnd = .distantPast
            }
            return (current: (start, now), prior: (priorStart, priorEnd))
        }
    }

    // MARK: - Computed

    private var aggregator: UsageAggregator {
        let snapshot = pricingSnapshot
        return UsageAggregator { providerID, modelID in
            guard let providerID, !providerID.isEmpty, !modelID.isEmpty else { return nil }
            return snapshot["\(providerID)/\(modelID)"]
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headlineCard
                costOverTimeChart
                breakdownPanels
                taskLedger
            }
            .padding(20)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(AppColors.background)
        .task {
            await loadRecords()
        }
        .onChange(of: shared.hasLoadedPersistedState, initial: false) {
            Task { await loadRecords() }
        }
        .refreshable {
            await loadRecords()
        }
        .onChange(of: selectedRange) {
            recomputeDerivedState()
        }
        .overlay {
            if isLoading {
                ProgressView("Loading usage data...")
            }
        }
        .sheet(item: $selectedTaskID) { taskID in
            let taskCount = aggregator.byTask(filteredRecords).keys.compactMap({ $0 }).count
            // Usage records can come from any session; this sheet has no easy way to
            // locate the source AgentTask without threading every session's task list
            // through the dashboard. For now, the task-detail sheet renders a generic
            // view when the `task` is nil — a reasonable degradation.
            TaskCostDetailSheet(
                taskID: taskID,
                task: nil,
                records: filteredRecords.filter { $0.taskID == taskID },
                allRecordsSummary: currentSummary,
                taskCountInRange: max(1, taskCount),
                aggregator: aggregator,
                providerNames: providerNames
            )
        }
    }

    private func loadRecords() async {
        isLoading = true
        allRecords = await shared.usageStore.allRecords()
        // Snapshot pricing keyed by "providerID/modelID" so the aggregator closure
        // doesn't need to cross the main-actor boundary at query time.
        var pricing: [String: ModelPricing] = [:]
        for model in shared.llmKit.models {
            // model.id == "providerID/modelID"; skip entries with empty components
            // that would produce nonsensical keys like "providerID/" or "/modelID".
            if let p = model.pricing, !model.id.hasSuffix("/"), !model.id.hasPrefix("/") {
                pricing[model.id] = p
            }
        }
        pricingSnapshot = pricing
        // Snapshot provider display names so we can resolve "builtin.mistral" → "Mistral".
        var names: [String: String] = [:]
        for provider in shared.llmKit.providers {
            names[provider.id] = provider.name
        }
        providerNames = names
        recomputeDerivedState()
        isLoading = false
    }

    /// Recomputes cached derived state from `allRecords`, `selectedRange`, and
    /// `pricingSnapshot`. Called after data loads and when the time range changes.
    /// Avoids redundant O(n) passes — without caching, each computed property
    /// was recalculated on every body evaluation (5-7 accesses per render).
    /// NOTE: If `allRecords` is ever set outside `loadRecords()`, this must be
    /// called afterward (or an `.onChange(of: allRecords)` handler added).
    private func recomputeDerivedState() {
        let interval = selectedRange.dateInterval()
        if selectedRange == .all {
            filteredRecords = allRecords
            priorRecords = []
        } else {
            filteredRecords = allRecords.filter { $0.timestamp >= interval.current.start && $0.timestamp <= interval.current.end }
            priorRecords = allRecords.filter { $0.timestamp >= interval.prior.start && $0.timestamp < interval.prior.end }
        }
        let agg = aggregator
        currentSummary = agg.summarize(filteredRecords, scopeLabel: selectedRange.rawValue)
        priorSummary = agg.summarize(priorRecords, scopeLabel: "Prior \(selectedRange.rawValue)")
    }

    // MARK: - Section 1: Headline Card

    private var headlineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                // Big cost number
                Text(formatCost(currentSummary.totalCostUSD))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                // Delta vs prior period
                if selectedRange != .all {
                    deltaLabel
                }

                Spacer()

                // Time range picker
                Picker("Range", selection: $selectedRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            // Quick stats row
            HStack(spacing: 24) {
                statPill(
                    label: "Calls",
                    value: "\(currentSummary.callCount.formatted())"
                )
                statPill(
                    label: "Tokens",
                    value: formatTokenCount(currentSummary.totalInputTokens + currentSummary.totalOutputTokens)
                )
                statPill(
                    label: "Avg / Call",
                    value: formatCost(currentSummary.avgCostUSD)
                )
                statPill(
                    label: "Cache Hit",
                    value: String(format: "%.0f%%", currentSummary.cacheHitRate * 100)
                )
                if currentSummary.unpricedCallCount > 0 {
                    statPill(
                        label: "Unpriced",
                        value: "\(currentSummary.unpricedCallCount)",
                        color: .orange
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.secondaryBackground)
        )
    }

    @ViewBuilder
    private var deltaLabel: some View {
        let delta = currentSummary.totalCostUSD - priorSummary.totalCostUSD
        let isUp = delta >= 0
        let arrow = isUp ? "arrow.up.right" : "arrow.down.right"
        let color: Color = isUp ? .red : .green

        HStack(spacing: 2) {
            Image(systemName: arrow)
                .font(.caption)
            Text(formatCost(abs(delta)))
                .font(.callout.weight(.medium))
            Text("vs prior")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(priorSummary.callCount > 0 ? color : .secondary)
    }

    private func statPill(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    // MARK: - Section 2: Cost Over Time Chart

    /// Chart data item with a stable identity for SwiftUI Charts.
    private struct ChartItem: Identifiable {
        let id: String  // "providerName|date"
        let date: Date
        let provider: String
        let cost: Double
    }

    private var costOverTimeChart: some View {
        let bucketUnit: Calendar.Component = selectedRange == .all ? .month : .day
        let byProvider = aggregator.byProvider(filteredRecords)
        let providerIDs = byProvider.keys.compactMap { $0 }.sorted()

        // Build time-series data: for each provider, get daily/monthly buckets
        var chartItems: [ChartItem] = []
        for providerID in providerIDs {
            let providerRecords = filteredRecords.filter { $0.providerID == providerID }
            let buckets = aggregator.byTimeBucket(providerRecords, unit: bucketUnit)
            let displayName = providerDisplayName(providerID)
            for (date, summary) in buckets {
                chartItems.append(ChartItem(
                    id: "\(displayName)|\(date.timeIntervalSinceReferenceDate)",
                    date: date, provider: displayName, cost: summary.totalCostUSD
                ))
            }
        }
        chartItems.sort { $0.date < $1.date }

        // Group by date for the hover tooltip
        let itemsByDate = Dictionary(grouping: chartItems, by: \.date)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Cost Over Time")
                .font(AppFonts.sectionHeader)

            if chartItems.isEmpty {
                ContentUnavailableView(
                    "No cost data",
                    systemImage: "chart.bar",
                    description: Text("No priced records in the selected range.")
                )
                .frame(height: 200)
            } else {
                Chart {
                    ForEach(chartItems) { item in
                        BarMark(
                            x: .value("Date", item.date, unit: bucketUnit),
                            y: .value("Cost", item.cost)
                        )
                        .foregroundStyle(by: .value("Provider", item.provider))
                    }

                    // Hover indicator: single RuleMark + annotation, rendered once
                    // (outside the ForEach so it doesn't duplicate per provider).
                    if let hoveredDate = chartHoveredDate {
                        RuleMark(x: .value("Hovered", hoveredDate, unit: bucketUnit))
                            .foregroundStyle(.gray.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                            .annotation(
                                position: .top,
                                spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                            ) {
                                chartTooltip(for: hoveredDate, items: itemsByDate[hoveredDate] ?? [], bucketUnit: bucketUnit)
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(format: .currency(code: "USD"))
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let origin = geo[plotFrame].origin
                                    let x = location.x - origin.x
                                    if let date: Date = proxy.value(atX: x) {
                                        let cal = Calendar.current
                                        let snapped = cal.dateInterval(of: bucketUnit, for: date)?.start ?? date
                                        chartHoveredDate = snapped
                                    }
                                case .ended:
                                    chartHoveredDate = nil
                                }
                            }
                    }
                }
                .frame(height: 220)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.secondaryBackground)
        )
    }

    /// Tooltip shown when hovering over a bar in the cost-over-time chart.
    private func chartTooltip(for date: Date, items: [ChartItem], bucketUnit: Calendar.Component) -> some View {
        let formatter = DateFormatter()
        switch bucketUnit {
        case .month: formatter.dateFormat = "MMM yyyy"
        default: formatter.dateFormat = "MMM d, yyyy"
        }
        let total = items.reduce(0.0) { $0 + $1.cost }

        return VStack(alignment: .leading, spacing: 4) {
            Text(formatter.string(from: date))
                .font(.caption.weight(.semibold))
            ForEach(items.sorted(by: { $0.cost > $1.cost })) { item in
                HStack(spacing: 4) {
                    Text(item.provider)
                        .font(.caption2)
                    Spacer(minLength: 8)
                    Text(formatCost(item.cost))
                        .font(.caption2.monospacedDigit())
                }
            }
            if items.count > 1 {
                Divider()
                HStack {
                    Text("Total")
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(formatCost(total))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThickMaterial)
                .shadow(radius: 4)
        )
    }

    // MARK: - Section 3: Breakdown Panels

    private var breakdownPanels: some View {
        let summary = currentSummary

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            // By Provider
            breakdownCard(title: "By Provider") {
                let byProvider = aggregator.byProvider(filteredRecords)
                    .compactMap { k, v -> (String, String, UsageSummary)? in
                        guard let k else { return nil }
                        return (k, providerDisplayName(k), v)
                    }
                    .sorted { $0.2.totalCostUSD > $1.2.totalCostUSD }

                ForEach(byProvider, id: \.0) { _, displayName, provSummary in
                    providerBar(
                        name: displayName,
                        cost: provSummary.totalCostUSD,
                        fraction: summary.totalCostUSD > 0 ? provSummary.totalCostUSD / summary.totalCostUSD : 0
                    )
                }
            }

            // By Agent
            breakdownCard(title: "By Agent") {
                let byAgent = aggregator.byAgent(filteredRecords)
                    .sorted { $0.value.totalCostUSD > $1.value.totalCostUSD }

                ForEach(byAgent, id: \.key) { role, agentSummary in
                    providerBar(
                        name: role.displayName,
                        cost: agentSummary.totalCostUSD,
                        fraction: summary.totalCostUSD > 0 ? agentSummary.totalCostUSD / summary.totalCostUSD : 0,
                        color: AppColors.color(for: .agent(role))
                    )
                }
            }

            // By Model
            breakdownCard(title: "By Model") {
                let byModel = aggregator.byModel(filteredRecords)
                    .sorted { $0.value.totalCostUSD > $1.value.totalCostUSD }
                    .prefix(8)

                ForEach(Array(byModel), id: \.key) { model, modelSummary in
                    HStack(spacing: 0) {
                        Text(model)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(formatCost(modelSummary.totalCostUSD))
                            .font(.caption.monospacedDigit())
                            .frame(width: 70, alignment: .trailing)
                        Text("\(modelSummary.callCount) calls")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }

            // Tool distribution
            breakdownCard(title: "Tool Calls") {
                let toolCounts = toolFrequencyFromRecords(filteredRecords)
                    .sorted { $0.value > $1.value }
                    .prefix(8)

                if toolCounts.isEmpty {
                    Text("No tool call data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(toolCounts), id: \.key) { tool, count in
                        HStack(spacing: 0) {
                            Text(tool)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func breakdownCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFonts.sectionHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.secondaryBackground)
        )
    }

    private func providerBar(name: String, cost: Double, fraction: Double, color: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(formatCost(cost))
                    .font(.caption.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
                Text(String(format: "%3.0f%%", fraction * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            // Bar constrained to the name area — stops before the cost/% columns
            // (106 = 70 cost + 36 percentage widths from the HStack above)
            HStack(spacing: 0) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.7))
                        .frame(width: max(2, geo.size.width * fraction))
                }
                .frame(height: 6)
                Spacer()
                    .frame(width: 106)
            }
        }
    }

    // MARK: - Section 4: Task Ledger

    private var taskLedger: some View {
        // Tasks live per-session now. The dashboard doesn't have access to every session's
        // task list from here, so task titles fall back to a truncated UUID. A future
        // enhancement could take `SessionManager` and union tasks across sessions.
        let taskLookup: [UUID: AgentTask] = [:]
        let grouped = aggregator.byTask(filteredRecords)
        let planningSummary = grouped[nil]
        let byTask = grouped
            .compactMap { k, v -> (UUID, String, UsageSummary)? in
                guard let k else { return nil }
                let title = taskLookup[k]?.title ?? "Task \(k.uuidString.prefix(8))"
                return (k, title, v)
            }
            .sorted { $0.2.totalCostUSD > $1.2.totalCostUSD }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Tasks")
                .font(AppFonts.sectionHeader)

            if byTask.isEmpty && planningSummary == nil {
                Text("No task data in selected range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("Task").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Cost").frame(width: 80, alignment: .trailing)
                    Text("Calls").frame(width: 60, alignment: .trailing)
                    Text("Tokens").frame(width: 80, alignment: .trailing)
                    Text("Latency").frame(width: 80, alignment: .trailing)
                    Text("Tools").frame(width: 60, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

                Divider()

                ForEach(byTask.prefix(50), id: \.0) { taskID, title, taskSummary in
                    taskRow(title: title, summary: taskSummary)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTaskID = taskID }
                        .background(hoveredTaskID == taskID ? Color.accentColor.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onHover { hovering in hoveredTaskID = hovering ? taskID : nil }
                }

                // Show unattributed planning overhead (Smith calls before any task existed)
                if let planningSummary, planningSummary.callCount > 0 {
                    taskRow(title: "Planning overhead", summary: planningSummary)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.secondaryBackground)
        )
    }

    private func taskRow(title: String, summary: UsageSummary) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatCost(summary.totalCostUSD))
                .font(.caption.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Text("\(summary.callCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            Text(formatTokenCount(summary.totalInputTokens + summary.totalOutputTokens))
                .font(.caption.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Text(formatLatency(summary.totalLatencyMs))
                .font(.caption.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Text("\(summary.totalToolCalls)")
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    /// Resolves a provider ID to its display name, falling back to the raw ID.
    private func providerDisplayName(_ id: String) -> String {
        providerNames[id] ?? id
    }

    /// Counts tool invocations across all records by flattening toolCallNames.
    private func toolFrequencyFromRecords(_ records: [UsageRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in records {
            guard let names = record.toolCallNames else { continue }
            for name in names {
                counts[name, default: 0] += 1
            }
        }
        return counts
    }

    private func formatCost(_ cost: Double) -> String {
        String(format: "$%.2f", cost)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms >= 60_000 {
            return String(format: "%.1fm", Double(ms) / 60_000)
        } else if ms >= 1_000 {
            return String(format: "%.1fs", Double(ms) / 1_000)
        } else {
            return "\(ms)ms"
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        if totalSeconds >= 3600 {
            return "\(totalSeconds / 3600)h \((totalSeconds % 3600) / 60)m"
        } else if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        } else {
            return "\(totalSeconds)s"
        }
    }
}

// MARK: - UUID + Identifiable (for .sheet(item:))

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

// MARK: - Task Cost Detail Sheet

/// Sheet showing detailed cost and usage metrics for a single task.
/// Opened by clicking a task row in the Spending Dashboard's task ledger.
private struct TaskCostDetailSheet: View {
    let taskID: UUID
    let task: AgentTask?
    let records: [UsageRecord]
    let allRecordsSummary: UsageSummary
    /// Number of distinct tasks in the parent dashboard's filtered time range,
    /// used to compute "vs average task cost" comparison.
    let taskCountInRange: Int
    let aggregator: UsageAggregator
    let providerNames: [String: String]

    @Environment(\.dismiss) private var dismiss

    private var summary: UsageSummary {
        aggregator.summarize(records, scopeLabel: task?.title ?? "Unknown")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                costBreakdownSection
                efficiencySection
                toolUsageSection
                configurationSection
                turnTimelineSection

                // Task ID in the lower right corner
                HStack {
                    Spacer()
                    Text(taskID.uuidString)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(AppColors.background)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(task?.title ?? "Unknown Task")
                    .font(.title2.bold())
                Spacer()
                if let task {
                    HStack(spacing: 4) {
                        Image(systemName: TaskStatusBadge.icon(for: task.status))
                            .foregroundStyle(TaskStatusBadge.color(for: task.status))
                        Text(task.status.rawValue.capitalized)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(TaskStatusBadge.color(for: task.status))
                    }
                }
            }

            HStack(spacing: 20) {
                headerStat(label: "Total Cost", value: formatCost(summary.totalCostUSD))
                headerStat(label: "LLM Calls", value: "\(summary.callCount)")
                headerStat(label: "Tokens", value: formatTokenCount(summary.totalInputTokens + summary.totalOutputTokens))

                if let task {
                    if let started = task.startedAt {
                        let end = task.completedAt ?? Date()
                        headerStat(label: "Duration", value: formatDuration(end.timeIntervalSince(started)))
                    }
                }

                // Comparison to average task cost across the time range
                if allRecordsSummary.callCount > 0 && taskCountInRange > 0 {
                    let avgTaskCost = allRecordsSummary.totalCostUSD / Double(taskCountInRange)
                    if avgTaskCost > 0 {
                        let ratio = summary.totalCostUSD / avgTaskCost
                        headerStat(
                            label: "vs Average",
                            value: String(format: "%.1fx", ratio),
                            color: ratio > 2 ? .red : ratio > 1 ? .orange : .green
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.secondaryBackground))
    }

    // MARK: - Cost Breakdown

    private var costBreakdownSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // By Agent Role
            card(title: "Cost by Agent") {
                let byAgent = aggregator.byAgent(records)
                    .sorted { $0.value.totalCostUSD > $1.value.totalCostUSD }
                ForEach(byAgent, id: \.key) { role, agentSummary in
                    costRow(
                        name: role.displayName,
                        cost: agentSummary.totalCostUSD,
                        detail: "\(agentSummary.callCount) calls",
                        color: AppColors.color(for: .agent(role))
                    )
                }
                if !byAgent.contains(where: { $0.key == .smith }) {
                    Text("Smith's costs are not attributed to individual tasks (Smith orchestrates but is not assigned as a task worker).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            // By Token Category
            card(title: "Token Breakdown") {
                let s = summary
                tokenRow(label: "Uncached Input", count: s.totalUncachedInputTokens, cost: s.inputCostUSD)
                tokenRow(label: "Output", count: s.totalOutputTokens, cost: s.outputCostUSD)
                tokenRow(label: "Cache Read", count: s.totalCacheReadTokens, cost: s.cacheReadCostUSD)
                tokenRow(label: "Cache Write", count: s.totalCacheWriteTokens, cost: s.cacheWriteCostUSD)
                Divider()
                HStack {
                    Text("Cache Hit Rate")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%%", s.cacheHitRate * 100))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
        }
    }

    // MARK: - Efficiency Metrics

    private var efficiencySection: some View {
        card(title: "Efficiency") {
            let s = summary
            HStack(spacing: 24) {
                miniStat(label: "Avg Cost / Call", value: formatCost(s.avgCostUSD))
                miniStat(label: "Avg Tokens / Call", value: formatTokenCount(Int(s.avgInputTokens + s.avgOutputTokens)))
                miniStat(label: "Avg Latency", value: formatLatency(Int(s.avgLatencyMs)))
                miniStat(label: "LLM Time", value: formatLatency(s.totalLatencyMs))
                miniStat(label: "Tool Exec Time", value: formatLatency(s.totalToolExecutionMs))

                let contextResets = records.filter { $0.preResetInputTokens != nil }.count
                if contextResets > 0 {
                    miniStat(label: "Context Resets", value: "\(contextResets)", color: .orange)
                }
            }
        }
    }

    // MARK: - Tool Usage

    private var toolUsageSection: some View {
        card(title: "Tool Usage") {
            let toolCounts = toolFrequency(records)
                .sorted { $0.value > $1.value }
            if toolCounts.isEmpty {
                Text("No tool call data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let maxCount = toolCounts.first?.value ?? 1
                ForEach(toolCounts.prefix(12), id: \.key) { tool, count in
                    HStack(spacing: 8) {
                        Text(tool)
                            .font(.caption)
                            .frame(width: 160, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.5))
                                .frame(width: max(2, geo.size.width * Double(count) / Double(maxCount)))
                        }
                        .frame(height: 8)
                        Text("\(count)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configurationSection: some View {
        let configs = Set(records.compactMap { $0.configuration?.id })
        let configRecords = records.compactMap(\.configuration)
        if let primaryConfig = configRecords.first {
            card(title: "Configuration") {
                HStack(spacing: 24) {
                    miniStat(label: "Model", value: primaryConfig.model)
                    miniStat(label: "Temperature", value: primaryConfig.useDefaultTemperature ? "default" : String(format: "%.1f", primaryConfig.temperature))
                    miniStat(label: "Max Output", value: formatTokenCount(primaryConfig.maxTokens))
                    miniStat(label: "Context Window", value: formatTokenCount(primaryConfig.contextWindowSize))
                    if configs.count > 1 {
                        miniStat(label: "Configs Used", value: "\(configs.count)", color: .orange)
                    }
                }
            }
        }
    }

    // MARK: - Turn Timeline

    private var turnTimelineSection: some View {
        card(title: "Turn-by-Turn (\(records.count) calls)") {
            let sorted = records.sorted { $0.timestamp < $1.timestamp }
            let displayedTurns = Array(sorted.suffix(100))
            let startOffset = sorted.count - displayedTurns.count

            if sorted.count > 100 {
                Text("Showing last 100 of \(sorted.count) turns")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Header
            HStack(spacing: 0) {
                Text("#").frame(width: 30, alignment: .trailing)
                Text("Agent").frame(width: 60, alignment: .leading).padding(.leading, 8)
                Text("In").frame(width: 60, alignment: .trailing)
                Text("Out").frame(width: 60, alignment: .trailing)
                Text("Cost").frame(width: 60, alignment: .trailing)
                Text("Latency").frame(width: 60, alignment: .trailing)
                Text("Tools").frame(width: 150, alignment: .leading).padding(.leading, 8)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(Array(displayedTurns.enumerated()), id: \.element.id) { index, record in
                let turnCost = computeTurnCost(record)
                HStack(spacing: 0) {
                    Text("\(startOffset + index + 1)")
                        .frame(width: 30, alignment: .trailing)
                    Text(record.agentRole.displayName)
                        .foregroundStyle(AppColors.color(for: .agent(record.agentRole)))
                        .frame(width: 60, alignment: .leading)
                        .padding(.leading, 8)
                    Text(formatTokenCount(record.inputTokens))
                        .frame(width: 60, alignment: .trailing)
                    Text(formatTokenCount(record.outputTokens))
                        .frame(width: 60, alignment: .trailing)
                    Text(formatCost(turnCost))
                        .frame(width: 60, alignment: .trailing)
                    Text(formatLatency(record.latencyMs))
                        .frame(width: 60, alignment: .trailing)
                    Text((record.toolCallNames ?? []).joined(separator: ", "))
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                        .padding(.leading, 8)
                }
                .font(.caption2.monospacedDigit())
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Helpers

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppFonts.sectionHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.secondaryBackground))
    }

    private func headerStat(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(color)
        }
    }

    private func miniStat(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
    }

    private func costRow(name: String, cost: Double, detail: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.caption)
            Spacer()
            Text(formatCost(cost)).font(.caption.monospacedDigit())
            Text(detail).font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
    }

    private func tokenRow(label: String, count: Int, cost: Double) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(formatTokenCount(count)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
            Text(formatCost(cost)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
        }
    }

    private func toolFrequency(_ records: [UsageRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in records {
            for name in r.toolCallNames ?? [] { counts[name, default: 0] += 1 }
        }
        return counts
    }

    private func computeTurnCost(_ record: UsageRecord) -> Double {
        guard let providerID = record.providerID else { return 0 }
        guard let pricing = aggregator.pricingLookup(providerID, record.modelID) else { return 0 }
        let rates = pricing.effectiveRates(totalInputTokens: record.inputTokens)
        let uncached = max(0, record.inputTokens - record.cacheReadTokens - record.cacheWriteTokens)
        return Double(uncached) * (rates.input ?? 0)
             + Double(record.outputTokens) * (rates.output ?? 0)
             + Double(record.cacheReadTokens) * (rates.cacheRead ?? 0)
             + Double(record.cacheWriteTokens) * (rates.cacheWrite ?? 0)
    }

    private func formatCost(_ cost: Double) -> String { String(format: "$%.2f", cost) }
    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }
    private func formatLatency(_ ms: Int) -> String {
        if ms >= 60_000 { return String(format: "%.1fm", Double(ms) / 60_000) }
        if ms >= 1_000 { return String(format: "%.1fs", Double(ms) / 1_000) }
        return "\(ms)ms"
    }
    private func formatDuration(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}
