import Foundation

/// Allows Jones to inspect running processes for safety monitoring.
private struct ListProcessesTool: AgentTool {
    let name = "list_processes"
    let toolDescription = "Lists running processes on the system. Use to check for runaway or suspicious processes spawned by other agents."

    let parameters: [String: AnyCodable] = [
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

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        let filter: String?
        if case .string(let f) = arguments["filter"], !f.isEmpty {
            filter = f
        } else {
            filter = nil
        }

        let result = try await ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["aux"],
            workingDirectory: nil,
            timeout: 10
        )

        if result.timedOut {
            return .failure("ps timed out\n\(result.output)")
        }
        if result.exitCode != 0 {
            return .failure("ps exit code \(result.exitCode)\n\(result.output)")
        }

        let output = result.output

        let allLines = output.components(separatedBy: "\n")
        let lines: [String]
        if let filter {
            // Filter in Swift to avoid shell injection — keep header + matching lines
            let loweredFilter = filter.lowercased()
            let header = allLines.first ?? ""
            let matching = allLines.dropFirst().filter { $0.lowercased().contains(loweredFilter) }
            lines = [header] + matching
        } else {
            lines = allLines
        }

        return .success(lines.joined(separator: "\n"))
    }
}
