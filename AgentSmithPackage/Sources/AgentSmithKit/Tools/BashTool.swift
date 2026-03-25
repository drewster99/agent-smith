import Foundation

/// Executes commands via /bin/bash login shell for better PATH/environment availability.
/// Shares the same safety blocklist as ShellTool.
public struct BashTool: AgentTool {
    public let name = "bash"
    public let toolDescription = "Execute a command via bash login shell (/bin/bash -l). Picks up PATH entries from ~/.bash_profile, ~/.bashrc, etc. Use when commands depend on Homebrew, nvm, pyenv, or similar tools."

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
                "description": .string("The command to execute in a bash login shell.")
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

        return try await runProcess(
            command: command,
            workingDirectory: workingDir,
            timeout: TimeInterval(timeoutSeconds)
        )
    }

    private func runProcess(
        command: String,
        workingDirectory: String?,
        timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-l", "-c", command]
                process.standardOutput = pipe
                process.standardError = pipe

                if let workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                }

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutItem
                )

                do {
                    try process.run()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeoutItem.cancel()

                    let output = String(data: data, encoding: .utf8)
                        ?? "Error: output could not be decoded as UTF-8 (\(data.count) bytes)"
                    let status = process.terminationStatus

                    if status == 0 {
                        continuation.resume(returning: output.isEmpty ? "(no output)" : output)
                    } else {
                        continuation.resume(
                            returning: "Exit code \(status)\n\(output)"
                        )
                    }
                } catch {
                    timeoutItem.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
