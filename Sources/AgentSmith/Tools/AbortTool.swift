import Foundation

/// Emergency abort tool for Jones. Stops all agents; requires user interaction to restart.
public struct AbortTool: AgentTool {
    public let name = "abort"
    public let toolDescription = "Emergency abort: immediately stops ALL agents. The system cannot be restarted without user interaction. Use only for serious safety violations."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "reason": .dictionary([
                "type": .string("string"),
                "description": .string("Clear explanation of why the abort is necessary.")
            ])
        ]),
        "required": .array([.string("reason")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let reason) = arguments["reason"] else {
            throw ToolCallError.missingRequiredArgument("reason")
        }

        await context.abort(reason)
        return "ABORT executed. All agents stopped. User must restart the system."
    }
}
