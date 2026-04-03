import Foundation

/// Executes bash commands. Has a hard blocklist of dangerous patterns.
public struct BashTool: AgentTool {
    public let name = "bash"
    public let toolDescription = "Execute a bash command and return its output. Do not submit dangerous or excessively complex commands. Default timeout is 300 seconds — pass a higher `timeout` for long-running commands. Before calling, consider if you have multiple bash commands you want to run that at not dependent upon each other. If so, send up to 20 `bash` calls in a single response."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "the command output") +
                   BrownBehavior.terminationWarning
        default:
            return toolDescription
        }
    }

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "command": .dictionary([
                "type": .string("string"),
                "description": .string("The bash command to execute.")
            ]),
            "workingDirectory": .dictionary([
                "type": .string("string"),
                "description": .string("Optional working directory for the command.")
            ]),
            "timeout": .dictionary([
                "type": .string("integer"),
                "description": .string("Timeout in seconds. Defaults to 300.")
            ])
        ]),
        "required": .array([.string("command")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let command) = arguments["command"] else {
            throw ToolCallError.missingRequiredArgument("command")
        }

        if let rejection = CommandBlocklist.validate(command) {
            await context.channel.post(ChannelMessage(
                sender: .system,
                content: "\u{26A0}\u{FE0F} \(rejection)"
            ))
            return rejection
        }

        let timeoutSeconds: Int
        if case .int(let t) = arguments["timeout"] {
            timeoutSeconds = t
        } else {
            timeoutSeconds = 300
        }

        let workingDir: String?
        if case .string(let dir) = arguments["workingDirectory"] {
            workingDir = dir
        } else {
            workingDir = nil
        }

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-l", "-c", command],
            workingDirectory: workingDir,
            timeout: TimeInterval(timeoutSeconds)
        )

        if result.timedOut {
            return "Command timed out after \(timeoutSeconds) seconds\n\(result.output)"
        } else if result.exitCode == 0 {
            return result.output.isEmpty ? "(no output)" : result.output
        } else {
            return "Exit code \(result.exitCode)\n\(result.output)"
        }
    }
}
