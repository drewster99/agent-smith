import Foundation

/// Allows Smith or Jones to terminate an agent by ID.
public struct TerminateAgentTool: AgentTool {
    public let name = "terminate_agent"
    public let toolDescription = "Terminate a running agent by its ID. Used by Smith for lifecycle management and by Jones for safety enforcement."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "agent_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the agent to terminate.")
            ]),
            "reason": .dictionary([
                "type": .string("string"),
                "description": .string("Reason for termination.")
            ])
        ]),
        "required": .array([.string("agent_id"), .string("reason")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let agentIDString) = arguments["agent_id"] else {
            throw ToolCallError.missingRequiredArgument("agent_id")
        }
        guard let agentID = UUID(uuidString: agentIDString) else {
            return "Invalid agent ID format: \(agentIDString)"
        }
        guard case .string(let reason) = arguments["reason"] else {
            throw ToolCallError.missingRequiredArgument("reason")
        }

        let success = await context.terminateAgent(agentID)
        if success {
            await context.channel.post(ChannelMessage(
                sender: .agent(context.agentRole),
                content: "Terminated agent \(agentIDString): \(reason)"
            ))
            return "Agent \(agentIDString) terminated successfully."
        } else {
            return "Failed to terminate agent \(agentIDString) — agent not found or already stopped."
        }
    }
}
