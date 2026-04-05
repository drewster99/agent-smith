import Foundation

/// Allows Jones to terminate specific processes for safety.
public struct KillProcessTool: AgentTool {
    public let name = "kill_process"
    public let toolDescription = "Terminates a specific process by PID. Use to stop runaway or dangerous processes spawned by agents."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "pid": .dictionary([
                "type": .string("integer"),
                "description": .string("Process ID to terminate.")
            ]),
            "force": .dictionary([
                "type": .string("boolean"),
                "description": .string("If true, sends SIGKILL instead of SIGTERM. Default false.")
            ])
        ]),
        "required": .array([.string("pid")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        let pid: Int32
        switch arguments["pid"] {
        case .int(let value):
            guard let exact = Int32(exactly: value) else {
                return "Invalid PID: value out of Int32 range."
            }
            pid = exact
        case .double(let value):
            guard let exact = Int32(exactly: value) else {
                return "Invalid PID: value out of Int32 range."
            }
            pid = exact
        case .string(let value):
            guard let parsed = Int32(value) else {
                return "Error: invalid PID '\(value)'"
            }
            pid = parsed
        default:
            throw ToolCallError.missingRequiredArgument("pid")
        }

        // Safety: refuse to kill PID 1 (launchd) or our own process
        guard pid > 1 else {
            return "Error: refusing to kill PID \(pid) — system-critical process."
        }
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            return "Error: refusing to kill own process."
        }

        // Verify the process is owned by the current user.
        // Fail closed: if ownership cannot be determined, refuse to kill.
        let currentUser = ProcessInfo.processInfo.userName
        guard let owner = Self.processOwner(pid: pid) else {
            return "Error: cannot verify ownership of process \(pid) — refusing to kill."
        }
        guard owner == currentUser else {
            return "Error: refusing to kill process \(pid) — owned by '\(owner)', not current user '\(currentUser)'."
        }

        let force: Bool
        if case .bool(let value) = arguments["force"] {
            force = value
        } else {
            force = false
        }

        let signal: Int32 = force ? SIGKILL : SIGTERM
        let result = kill(pid, signal)

        if result == 0 {
            let signalName = force ? "SIGKILL" : "SIGTERM"
            await context.channel.post(ChannelMessage(
                sender: .system,
                content: "Sent \(signalName) to process \(pid)."
            ))
            return "Successfully sent \(signalName) to process \(pid)."
        } else {
            let error = String(cString: strerror(errno))
            return "Failed to kill process \(pid): \(error)"
        }
    }

    /// Returns the username owning a given PID, or nil if lookup fails.
    private static func processOwner(pid: Int32) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "user="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Nil return (empty output = process not found, or ps failure) causes the
        // caller to refuse the kill rather than proceed with unverified ownership.
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
