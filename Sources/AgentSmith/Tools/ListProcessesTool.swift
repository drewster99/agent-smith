import Foundation

/// Allows Jones to inspect running processes for safety monitoring.
public struct ListProcessesTool: AgentTool {
    public let name = "list_processes"
    public let toolDescription = "Lists running processes on the system. Use to check for runaway or suspicious processes spawned by other agents."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "filter": .dictionary([
                "type": .string("string"),
                "description": .string("Optional grep filter to narrow results (e.g., a process name).")
            ])
        ]),
        "required": .array([])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        let process = Process()
        let pipe = Pipe()

        if case .string(let filter) = arguments["filter"], !filter.isEmpty {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "ps aux | head -1; ps aux | grep -i \(shellEscape(filter)) | grep -v grep"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["aux"]
        }

        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Read pipe data BEFORE waitUntilExit to avoid deadlock:
        // if output exceeds pipe buffer (~64KB), the process blocks
        // on write while we'd block waiting for exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Truncate to avoid overwhelming context
        let lines = output.components(separatedBy: "\n")
        if lines.count > 100 {
            return lines.prefix(100).joined(separator: "\n") + "\n... (\(lines.count - 100) more lines truncated)"
        }
        return output
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
