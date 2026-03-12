import Foundation

/// Writes content to a file. Blocks writes to sensitive system and credential paths.
public struct FileWriteTool: AgentTool {
    public let name = "file_write"
    public let toolDescription = "Write content to a file at the given path. Creates parent directories if needed. Sensitive system paths are blocked."

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute or relative file path to write.")
            ]),
            "content": .dictionary([
                "type": .string("string"),
                "description": .string("The content to write to the file.")
            ])
        ]),
        "required": .array([.string("path"), .string("content")])
    ]

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let path) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        guard case .string(let content) = arguments["content"] else {
            throw ToolCallError.missingRequiredArgument("content")
        }

        if let rejection = Self.checkPathRestriction(path) {
            return rejection
        }

        let url = URL(fileURLWithPath: path)
        do {
            let parentDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "File written successfully: \(path)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }

    /// Returns an error message if the path is restricted, or nil if allowed.
    static func checkPathRestriction(_ path: String) -> String? {
        // Resolve relative paths AND symlinks so neither "../../../etc" nor symlink indirection can bypass checks
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let home = NSHomeDirectory()

        // Block system directories
        let systemPrefixes = [
            "/etc", "/System", "/Library", "/usr/", "/bin/", "/sbin/",
            "/var/", "/private/etc", "/private/var", "/dev/"
        ]
        for prefix in systemPrefixes {
            if resolved.hasPrefix(prefix) {
                return "BLOCKED: Cannot write to system path '\(path)'"
            }
        }

        // Block sensitive credential/config directories in home
        let sensitiveDirs = [".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker"]
        for dir in sensitiveDirs {
            let dirPath = (home as NSString).appendingPathComponent(dir)
            if resolved.hasPrefix(dirPath) {
                return "BLOCKED: Cannot write to sensitive directory '\(path)'"
            }
        }

        // Block shell config files in home
        let shellConfigs = [
            ".zshrc", ".bashrc", ".bash_profile", ".profile",
            ".zprofile", ".zshenv", ".zlogout", ".bash_logout"
        ]
        for config in shellConfigs {
            let configPath = (home as NSString).appendingPathComponent(config)
            if resolved == configPath {
                return "BLOCKED: Cannot write to shell configuration file '\(path)'"
            }
        }

        return nil
    }
}
