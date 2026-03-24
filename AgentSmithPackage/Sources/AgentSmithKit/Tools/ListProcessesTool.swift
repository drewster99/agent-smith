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
        let filter: String?
        if case .string(let f) = arguments["filter"], !f.isEmpty {
            filter = f
        } else {
            filter = nil
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["aux"]
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Read pipe data BEFORE waitUntilExit to avoid deadlock:
        // if output exceeds pipe buffer (~64KB), the process blocks
        // on write while we'd block waiting for exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            return "Error: process output could not be decoded as UTF-8 (\(data.count) bytes)."
        }

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

        return lines.joined(separator: "\n")
    }
}
