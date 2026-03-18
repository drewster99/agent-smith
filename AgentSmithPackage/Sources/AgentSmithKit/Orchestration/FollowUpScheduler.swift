import Foundation

/// Bridges the schedule_followup tool to an AgentActor.
/// Created before the agent exists so it can be captured by the ToolContext,
/// then wired to the real agent after creation.
actor FollowUpScheduler {
    private weak var agent: AgentActor?

    func set(agent: AgentActor) {
        self.agent = agent
    }

    func schedule(after delay: TimeInterval) async {
        await agent?.scheduleFollowUp(after: delay)
    }
}
