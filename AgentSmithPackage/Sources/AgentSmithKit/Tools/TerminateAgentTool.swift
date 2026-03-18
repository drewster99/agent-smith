import Foundation

/// Allows Smith or Jones to terminate an agent by ID.
/// Smith may only terminate Brown agents. Jones may only terminate Smith or Brown agents.
public struct TerminateAgentTool: AgentTool {
    public let name = "terminate_agent"
    public let toolDescription = "Terminate a running agent by its ID."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .smith:
            return "Terminate a running Brown agent by its ID."
        case .jones:
            return "Terminate a running agent by its ID. You may terminate Smith or Brown agents."
        default:
            return toolDescription
        }
    }

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
        guard case .string(let reason) = arguments["reason"] else {
            throw ToolCallError.missingRequiredArgument("reason")
        }
        guard let agentID = UUID(uuidString: agentIDString) else {
            return "Invalid agent ID format: \(agentIDString)"
        }

        let targetRole = await context.agentRoleForID(agentID)

        // Smith may only terminate Brown agents.
        if context.agentRole == .smith {
            guard targetRole == .brown else {
                return "Smith may only terminate Brown agents."
            }
        }

        // Jones may only terminate Smith or Brown agents — not itself or another Jones.
        if context.agentRole == .jones {
            guard targetRole == .smith || targetRole == .brown else {
                return "Jones may only terminate Smith or Brown agents."
            }
        }

        let success = await context.terminateAgent(agentID)
        if success {
            await context.channel.post(ChannelMessage(
                sender: .system,
                content: "Agent \(agentIDString) terminated: \(reason)"
            ))
            return "Agent \(agentIDString) terminated successfully."
        } else {
            return "Failed to terminate agent \(agentIDString) — agent not found or already stopped."
        }
    }
}
