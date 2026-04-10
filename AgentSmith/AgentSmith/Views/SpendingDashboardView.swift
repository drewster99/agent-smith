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
    @Bindable var viewModel: AppViewModel

    // MARK: - State

    @State private var selectedRange: TimeRange = .week
    @State private var allRecords: [UsageRecord] = []
    /// The date bucket currently hovered in the cost-over-time chart (nil = none).
    @State private var chartHoveredDate: Date?
    /// Snapshot of pricing data, captured on load so the aggregator closure doesn't
    /// need to cross actor boundaries.
    @State private var pricingSnapshot: [String: ModelPricing] = [:]
    /// Provider ID → display name lookup, captured on load.
    @State private var providerNames: [String: String] = [:]
    @State private var isLoading = true

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
                priorStart = calendar.date(byAdding: .day, value: -1, to: start)!
                priorEnd = start
            case .week:
                start = calendar.date(byAdding: .day, value: -7, to: now)!
                priorStart = calendar.date(byAdding: .day, value: -7, to: start)!
                priorEnd = start
            case .month:
                start = calendar.date(byAdding: .month, value: -1, to: now)!
                priorStart = calendar.date(byAdding: .month, value: -1, to: start)!
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
            guard let providerID else { return nil }
            return snapshot["\(providerID)/\(modelID)"]
        }
    }

    private var filteredRecords: [UsageRecord] {
        let interval = selectedRange.dateInterval()
        if selectedRange == .all { return allRecords }
        return allRecords.filter { $0.timestamp >= interval.current.start && $0.timestamp <= interval.current.end }
    }

    private var priorRecords: [UsageRecord] {
        let interval = selectedRange.dateInterval()
        if selectedRange == .all { return [] }
        return allRecords.filter { $0.timestamp >= interval.prior.start && $0.timestamp < interval.prior.end }
    }

    private var currentSummary: UsageSummary {
        aggregator.summarize(filteredRecords, scopeLabel: selectedRange.rawValue)
    }

    private var priorSummary: UsageSummary {
        aggregator.summarize(priorRecords, scopeLabel: "Prior \(selectedRange.rawValue)")
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
        .onChange(of: viewModel.hasLoadedPersistedState, initial: false) {
            Task { await loadRecords() }
        }
        .refreshable {
            await loadRecords()
        }
        .overlay {
            if isLoading {
                ProgressView("Loading usage data...")
            }
        }
    }

    private func loadRecords() async {
        isLoading = true
        allRecords = await viewModel.usageStore.allRecords()
        // Snapshot pricing keyed by "providerID/modelID" so the aggregator closure
        // doesn't need to cross the main-actor boundary at query time.
        var pricing: [String: ModelPricing] = [:]
        for model in viewModel.llmKit.models {
            if let p = model.pricing {
                pricing[model.id] = p  // model.id == "providerID/modelID"
            }
        }
        pricingSnapshot = pricing
        // Snapshot provider display names so we can resolve "builtin.mistral" → "Mistral".
        var names: [String: String] = [:]
        for provider in viewModel.llmKit.providers {
            names[provider.id] = provider.name
        }
        providerNames = names
        isLoading = false
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
        let taskLookup = Dictionary(uniqueKeysWithValues: viewModel.tasks.map { ($0.id, $0) })
        let byTask = aggregator.byTask(filteredRecords)
            .compactMap { k, v -> (UUID, String, UsageSummary)? in
                guard let k else { return nil }
                let title = taskLookup[k]?.title ?? "Task \(k.uuidString.prefix(8))"
                return (k, title, v)
            }
            .sorted { $0.2.totalCostUSD > $1.2.totalCostUSD }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Tasks")
                .font(AppFonts.sectionHeader)

            if byTask.isEmpty {
                Text("No task data in selected range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("Task").frame(width: 220, alignment: .leading)
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
                .frame(width: 220, alignment: .leading)
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
}
