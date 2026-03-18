import Foundation

/// Allows Smith to spawn a new Brown+Jones agent pair.
public struct SpawnBrownTool: AgentTool {
    public let name = "spawn_brown"
    public let toolDescription = "Spawn a new Brown agent (a Jones data archival agent starts alongside it automatically). Returns the Brown agent's ID. Send task instructions separately via send_message."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([:]),
        "required": .array([])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard let brownID = await context.spawnBrown() else {
            return "Failed to spawn Brown agent."
        }

        return "Brown agent spawned: \(brownID). Send it task instructions via send_message with recipient_id."
    }
}
