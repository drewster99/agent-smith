import Foundation

/// Reads the contents of a file. Blocks reads of sensitive credential paths.
public struct FileReadTool: AgentTool {
    public let name = "file_read"
    public let toolDescription = "Read the contents of a file at the given path. Sensitive credential paths are blocked."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute or relative file path to read.")
            ])
        ]),
        "required": .array([.string("path")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let path) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }

        if let rejection = Self.checkPathRestriction(path) {
            return rejection
        }

        let url = URL(fileURLWithPath: path)
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let truncated = content.prefix(50_000)
            if truncated.count < content.count {
                return String(truncated) + "\n\n[...truncated at 50,000 characters]"
            }
            return String(truncated)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }
    }

    /// Returns an error message if the path is restricted, or nil if allowed.
    static func checkPathRestriction(_ path: String) -> String? {
        // Resolve relative paths to absolute via CWD so "../../../.ssh" can't bypass checks
        let resolved = URL(fileURLWithPath: path).standardized.path
        let home = NSHomeDirectory()

        // Block sensitive credential directories
        let sensitiveDirs = [".ssh", ".gnupg", ".aws", ".kube"]
        for dir in sensitiveDirs {
            let dirPath = (home as NSString).appendingPathComponent(dir)
            if resolved.hasPrefix(dirPath) {
                return "BLOCKED: Cannot read sensitive credential path '\(path)'"
            }
        }

        // Block system credential files
        let systemCredentials = ["/etc/shadow", "/etc/master.passwd", "/private/etc/master.passwd"]
        for cred in systemCredentials {
            if resolved == cred || resolved.hasPrefix(cred) {
                return "BLOCKED: Cannot read system credential file '\(path)'"
            }
        }

        return nil
    }
}
