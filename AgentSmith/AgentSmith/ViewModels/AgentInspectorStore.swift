import SwiftUI
import AgentSmithKit
import SwiftLLMKit

/// Holds inspector state for all agents, updated incrementally via push callbacks.
///
/// Completely decoupled from `AppViewModel` so that inspector data changes
/// never invalidate MainView.body, ChannelLogView, or UserInputView.
@Observable
@MainActor
final class AgentInspectorStore {
    /// Per-turn LLM call records, pushed incrementally as each turn completes.
    var turnsByRole: [AgentRole: [LLMTurnRecord]] = [:]

    /// Security evaluation records from Jones/SecurityEvaluator.
    var evaluationRecords: [EvaluationRecord] = []

    // MARK: - Push API (called from runtime callbacks)

    /// Appends a newly completed LLM turn for the given agent role.
    func appendTurn(_ turn: LLMTurnRecord, for role: AgentRole) {
        turnsByRole[role, default: []].append(turn)
    }

    /// Appends a newly completed security evaluation record.
    func appendEvaluation(_ record: EvaluationRecord) {
        evaluationRecords.append(record)
    }

    /// Clears all data for a specific agent role (e.g. when agent is replaced).
    func clear(for role: AgentRole) {
        turnsByRole[role] = nil
    }

    /// Clears all inspector data (e.g. on full stop/reset).
    func clearAll() {
        turnsByRole.removeAll()
        evaluationRecords.removeAll()
    }

    // MARK: - Derived accessors

    /// Returns the latest context snapshot for a role, derived from its most recent turn.
    func contextMessages(for role: AgentRole) -> [LLMMessage] {
        turnsByRole[role]?.last?.contextSnapshot ?? []
    }

    /// Extracts the current system prompt for a role from its latest context snapshot.
    func systemPrompt(for role: AgentRole) -> String {
        contextMessages(for: role)
            .first { $0.role == .system }
            .flatMap { $0.content.textValue } ?? ""
    }
}
