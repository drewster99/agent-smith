import SwiftUI
import AgentSmithKit
import SwiftLLMKit

/// Centralized color definitions with semantic names.
enum AppColors {
    static let smithAgent = Color.green
    static let brownAgent = Color.orange
    static let jonesAgent = Color.red
    static let summarizerAgent = Color.blue
    static let userMessage = Color.blue
    static let systemMessage = Color.gray
    static let background = Color(.windowBackgroundColor)
    static let secondaryBackground = Color(.controlBackgroundColor)
    static let channelBackground = Color(.textBackgroundColor)
    static let errorBackground = Color.red.opacity(0.12)
    /// Subtle highlight for Smith→User private messages to draw attention to agent output.
    static let smithToUserBackground = Color.green.opacity(0.08)
    /// Accent for new-task banners in the channel log.
    static let taskCreatedAccent = Color.blue
    /// Accent for task-completed banners in the channel log.
    static let taskCompletedAccent = Color(red: 0.85, green: 0.65, blue: 0.13)
    /// Accent for task-acknowledged banners in the channel log.
    static let taskAcknowledgedAccent = Color.cyan
    /// Accent for task-update banners in the channel log.
    static let taskUpdateAccent = Color.orange
    /// Accent for Brown's task_complete submission (awaiting Smith's review).
    static let taskReadyForReviewAccent = Color.purple
    /// Accent for Smith's rejection / changes-requested messages.
    static let changesRequestedAccent = Color(red: 0.90, green: 0.35, blue: 0.35)

    /// Returns the color for a given channel message sender.
    static func color(for sender: ChannelMessage.Sender) -> Color {
        switch sender {
        case .agent(.smith): return smithAgent
        case .agent(.brown): return brownAgent
        case .agent(.jones): return jonesAgent
        case .agent(.summarizer): return summarizerAgent
        case .user: return userMessage
        case .system: return systemMessage
        }
    }
}

/// Centralized font definitions.
enum AppFonts {
    static let channelSender = Font.system(.caption, design: .monospaced, weight: .bold)
    static let channelBody = Font.system(.body, design: .monospaced)
    static let channelTimestamp = Font.system(.caption2, design: .monospaced)
    static let taskTitle = Font.headline
    static let taskDescription = Font.subheadline
    static let sectionHeader = Font.title3.bold()
    static let inputField = Font.system(.body, design: .monospaced)
    static let markdownH1 = Font.system(.title2, design: .default, weight: .bold)
    static let markdownH2 = Font.system(.title3, design: .default, weight: .bold)
    static let markdownH3 = Font.system(.headline, design: .default, weight: .bold)
    static let inspectorLabel = Font.system(.caption, design: .monospaced)
    static let inspectorBody = Font.system(.caption2, design: .monospaced)
}

/// Pricing display formatting.
enum PricingFormatter {
    /// Compact pricing summary string for display (e.g., "$3.00 in / $15.0 out per M").
    static func summary(_ pricing: ModelPricing) -> String {
        var parts: [String] = []
        if let input = pricing.base.input {
            parts.append("\(costPerMillion(input * 1_000_000)) in")
        }
        if let output = pricing.base.output {
            parts.append("\(costPerMillion(output * 1_000_000)) out")
        }
        guard !parts.isEmpty else { return "" }
        var result = parts.joined(separator: " / ") + " per M"
        if !pricing.tokenThresholdTiers.isEmpty {
            result += " (tiered)"
        }
        return result
    }

    /// Formats a cost-per-million-tokens value as a compact dollar string.
    static func costPerMillion(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1 {
            return String(format: "$%.2f", cost)
        } else {
            return String(format: "$%.1f", cost)
        }
    }
}

/// Task status badge styling.
enum TaskStatusBadge {
    static func color(for status: AgentTask.Status) -> Color {
        switch status {
        case .pending: return .gray
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .paused: return .indigo
        case .awaitingReview: return .orange
        case .interrupted: return .yellow
        case .scheduled: return .purple
        }
    }

    static func icon(for status: AgentTask.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .awaitingReview: return "eye.circle.fill"
        case .interrupted: return "exclamationmark.circle.fill"
        case .scheduled: return "clock.badge"
        }
    }
}
