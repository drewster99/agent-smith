import Foundation

/// Executes shell commands. Has a hard blocklist of dangerous patterns.
public struct ShellTool: AgentTool {
    public let name = "shell"
    public let toolDescription = "Execute a shell command and return its output. Dangerous commands are blocked."

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
                "description": .string("The shell command to execute.")
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
        "chown -R root",
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

    /// Sensitive paths that should not be accessible via shell commands.
    /// Mirrors the restrictions in FileReadTool and FileWriteTool.
    private static let sensitiveHomeDirs = [".ssh", ".gnupg", ".aws", ".kube", ".config/gcloud", ".docker"]
    private static let sensitiveSystemPaths = ["/etc/shadow", "/etc/master.passwd", "/private/etc/master.passwd"]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    /// Strips ALL whitespace and lowercases. This ensures that no amount of
    /// creative spacing (e.g. `:(  ){ : | : & } ; :`) can bypass the blocklist.
    private static func stripForComparison(_ input: String) -> String {
        String(input.lowercased().filter { !$0.isWhitespace })
    }

    /// Returns a rejection message if the command references sensitive credential paths, nil otherwise.
    /// Uses case-insensitive matching because macOS APFS is case-insensitive by default.
    private static func checkSensitivePaths(_ command: String) -> String? {
        let home = NSHomeDirectory()
        let lowered = command.lowercased()
        let homeLower = home.lowercased()

        // Expand common home-directory shorthands so absolute-path patterns match
        let expanded = lowered
            .replacingOccurrences(of: "~", with: homeLower)
            .replacingOccurrences(of: "$home", with: homeLower)
            .replacingOccurrences(of: "${home}", with: homeLower)

        for dir in sensitiveHomeDirs {
            let dirLower = dir.lowercased()
            let dirPath = (homeLower as NSString).appendingPathComponent(dirLower)
            let patterns = [dirPath, "~/\(dirLower)", "$home/\(dirLower)", "${home}/\(dirLower)"]
            for pattern in patterns where expanded.contains(pattern) || lowered.contains(pattern) {
                return "BLOCKED: Command references sensitive credential path '\(dir)'"
            }
        }

        for path in sensitiveSystemPaths where lowered.contains(path.lowercased()) {
            return "BLOCKED: Command references sensitive system credential file '\(path)'"
        }

        return nil
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let command) = arguments["command"] else {
            throw ToolCallError.missingRequiredArgument("command")
        }

        // Block commands that reference sensitive credential paths
        if let rejection = Self.checkSensitivePaths(command) {
            await context.channel.post(ChannelMessage(
                sender: .system,
                content: "\u{26A0}\u{FE0F} \(rejection)"
            ))
            return rejection
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

        // Block ALL indirection patterns (eval, bash -c, etc.) unconditionally.
        // These can be used to obfuscate arbitrary commands, making denylist
        // inspection unreliable.
        let lowered = command.lowercased()
        for pattern in Self.rawBlockedPatterns {
            if lowered.contains(pattern) {
                let rejection = "BLOCKED: Command uses indirection '\(pattern.trimmingCharacters(in: .whitespaces))' — execute the inner command directly instead"
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
