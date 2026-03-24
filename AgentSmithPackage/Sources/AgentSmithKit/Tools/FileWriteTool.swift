import Foundation

/// Writes content to a file. Blocks writes to sensitive system and credential paths.
public struct FileWriteTool: AgentTool {
    public let name = "file_write"
    public let toolDescription = "Write content to a file at the given absolute path. Creates parent directories if needed. Requires fully qualified paths (starting with /). Blocks writes to sensitive system paths and hard-linked files."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "a success confirmation") +
                   BrownBehavior.terminationWarning
        default:
            return toolDescription
        }
    }

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("Fully qualified (absolute) file path to write. Must start with /.")
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

        guard path.hasPrefix("/") else {
            return "BLOCKED: Path must be absolute (start with /). Got: \(path)"
        }

        if let rejection = Self.checkPathRestriction(path) {
            return rejection
        }

        let url = URL(fileURLWithPath: path)
        let resolvedURL = url.resolvingSymlinksInPath()
        let fm = FileManager.default

        // Check for hard links — if the target file exists and has multiple hard links,
        // writing to it could silently modify data reachable from other paths.
        if fm.fileExists(atPath: resolvedURL.path) {
            do {
                let attrs = try fm.attributesOfItem(atPath: resolvedURL.path)
                if let linkCount = attrs[.referenceCount] as? Int, linkCount > 1 {
                    return "BLOCKED: File '\(path)' has \(linkCount) hard links. Writing would affect all linked paths."
                }
            } catch {
                return "Error checking file attributes: \(error.localizedDescription)"
            }
        }

        do {
            let parentDir = resolvedURL.deletingLastPathComponent()
            try fm.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
            try content.write(to: resolvedURL, atomically: true, encoding: .utf8)

            // Report if the path traversed symlinks so the caller knows where the file actually landed.
            if resolvedURL.path != url.standardized.path {
                return "File written successfully: \(path) (resolved to \(resolvedURL.path) via symlink)"
            }
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

        // Block system directories.
        // Lowercase both sides: APFS is case-insensitive so /SYSTEM/... bypasses a case-sensitive check.
        let systemPrefixes = [
            "/etc", "/System", "/Library", "/usr/", "/bin/", "/sbin/",
            "/var/", "/private/etc", "/private/var", "/dev/"
        ]
        for prefix in systemPrefixes {
            if resolved.lowercased().hasPrefix(prefix.lowercased()) {
                return "BLOCKED: Cannot write to system path '\(path)'"
            }
        }

        // Block sensitive credential/config directories in home
        let sensitiveDirs = [".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker"]
        for dir in sensitiveDirs {
            let dirPath = (home as NSString).appendingPathComponent(dir)
            if resolved.lowercased().hasPrefix(dirPath.lowercased()) {
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
            if resolved.lowercased() == configPath.lowercased() {
                return "BLOCKED: Cannot write to shell configuration file '\(path)'"
            }
        }

        return nil
    }
}
