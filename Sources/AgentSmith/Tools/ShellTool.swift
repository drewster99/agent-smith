import Foundation

/// Executes shell commands. Has a hard blocklist of dangerous patterns.
public struct ShellTool: AgentTool {
    public let name = "shell"
    public let toolDescription = "Execute a shell command and return its output. Dangerous commands are blocked."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "command": .dictionary([
                "type": .string("string"),
                "description": .string("The shell command to execute.")
            ]),
            "workingDirectory": .dictionary([
                "type": .string("string"),
                "description": .string("Optional working directory for the command.")
            ]),
            "timeout": .dictionary([
                "type": .string("integer"),
                "description": .string("Timeout in seconds. Defaults to 30.")
            ])
        ]),
        "required": .array([.string("command")])
    ]

    /// Patterns that are unconditionally blocked, regardless of Jones.
    /// Compared with ALL whitespace stripped so no spacing trick can bypass them.
    private static let blockedPatterns: [String] = [
        "rm -rf /",
        "rm -rf /*",
        "rm -rf ~",
        "rm -rf ~/*",
        "rm -rf $home",
        "rm -rf \"$home\"",
        "rm -Rf /",
        "rm -Rf /*",
        "rm -r -f /",
        "rm -r -f /*",
        "mkfs",
        "dd if=",
        ":(){:|:&};:",          // fork bomb
        "chmod -R 777 /",
        "chown -R",
        "wget|sh",
        "curl|sh",
        "curl|bash",
        "wget|bash",
        "> /dev/sda",
        "> /dev/disk",
        "shutdown",
        "reboot",
        "halt",
        "init 0",
        "init 6",
        "launchctl unload",
        "base64 -d|sh",
        "base64 -d|bash",
        "base64 --decode|sh",
        "base64 --decode|bash",
        "find / -delete",
        "find / -exec rm",
    ]

    /// Additional patterns checked against the raw (non-stripped) command.
    /// These catch indirection techniques that could bypass the primary blocklist.
    private static let rawBlockedPatterns: [String] = [
        "eval ",
        "bash -c ",
        "sh -c ",
        "zsh -c ",
        "python -c ",
        "python3 -c ",
        "perl -e ",
        "ruby -e ",
    ]

    public init() {}

    /// Strips ALL whitespace and lowercases. This ensures that no amount of
    /// creative spacing (e.g. `:(  ){ : | : & } ; :`) can bypass the blocklist.
    private static func stripForComparison(_ input: String) -> String {
        String(input.lowercased().filter { !$0.isWhitespace })
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let command) = arguments["command"] else {
            throw ToolCallError.missingRequiredArgument("command")
        }

        // Hard blocklist check — belt portion of belt-and-suspenders.
        // Strip ALL whitespace from both command and pattern before comparing.
        // This means `:(){ :|:& };:` and `:(){:|:&};:` both become `:(){:|:&};:`
        let stripped = Self.stripForComparison(command)
        for pattern in Self.blockedPatterns {
            let strippedPattern = Self.stripForComparison(pattern)
            if stripped.contains(strippedPattern) {
                let rejection = "BLOCKED: Command rejected by safety blocklist — '\(command)' matches blocked pattern '\(pattern)'"
                await context.channel.post(ChannelMessage(
                    sender: .system,
                    content: "\u{26A0}\u{FE0F} \(rejection)"
                ))
                return rejection
            }
        }

        // Check raw command for indirection patterns (eval, bash -c, etc.)
        let lowered = command.lowercased()
        for pattern in Self.rawBlockedPatterns {
            guard let matchRange = lowered.range(of: pattern) else { continue }
            // Allow if the inner content seems safe (e.g., `bash -c "echo hi"`)
            // Block if it contains any destructive keyword
            let destructiveKeywords = ["rm ", "mkfs", "dd if", "chmod", "chown", "del ", "format"]
            let afterPattern = String(lowered[matchRange.upperBound...])
            if destructiveKeywords.contains(where: { afterPattern.contains($0) }) {
                let rejection = "BLOCKED: Command uses indirection '\(pattern.trimmingCharacters(in: .whitespaces))' with destructive content"
                await context.channel.post(ChannelMessage(
                    sender: .system,
                    content: "\u{26A0}\u{FE0F} \(rejection)"
                ))
                return rejection
            }
        }

        let timeoutSeconds: Int
        if case .int(let t) = arguments["timeout"] {
            timeoutSeconds = t
        } else {
            timeoutSeconds = 30
        }

        let workingDir: String?
        if case .string(let dir) = arguments["workingDirectory"] {
            workingDir = dir
        } else {
            workingDir = nil
        }

        // Post the command being executed to the channel for Jones to monitor
        await context.channel.post(ChannelMessage(
            sender: .agent(context.agentRole),
            content: "Executing shell command: `\(command)`",
            metadata: ["tool": .string("shell"), "command": .string(command)]
        ))

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
        // Dispatch blocking Process operations to a GCD thread to avoid
        // blocking Swift concurrency's cooperative thread pool.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
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

                    // Read pipe data BEFORE waitUntilExit to avoid deadlock:
                    // if output exceeds pipe buffer (~64KB), the process blocks
                    // on write while we'd block waiting for exit.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeoutItem.cancel()

                    let output = String(data: data, encoding: .utf8) ?? ""
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
