import Foundation

/// Reads the contents of a file. Blocks reads of sensitive credential paths.
public struct FileReadTool: AgentTool {
    public let name = "file_read"
    public let toolDescription = "Read the contents of a file at the given path. Sensitive credential paths are blocked. Maximum file size: 250,000 characters."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "the file contents")
        default:
            return toolDescription
        }
    }

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

    /// Maximum file size in characters that can be read.
    static let maxCharacters = 250_000

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown || context.agentRole == .smith || context.agentRole == .jones
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let path = (rawPath as NSString).expandingTildeInPath

        if let rejection = Self.checkPathRestriction(path) {
            return rejection
        }

        let url = URL(fileURLWithPath: path)
        let resolvedPath = url.resolvingSymlinksInPath().path

        // Check file size before reading to avoid loading huge files into memory.
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: resolvedPath)
            if let fileSize = attrs[.size] as? UInt64, fileSize > Self.maxCharacters {
                return "Error: File is too large to read (\(fileSize) bytes, maximum is \(Self.maxCharacters))."
            }
        } catch {
            return "Error checking file size: \(error.localizedDescription)"
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            guard content.count <= Self.maxCharacters else {
                return "Error: File is too large to read (\(content.count) characters, maximum is \(Self.maxCharacters))."
            }
            // Record this file as read in the current session for file_edit gating.
            // Only Brown's reads count — Smith and Jones reads must not gate Brown's file_edit.
            if context.agentRole == .brown {
                context.recordFileRead(resolvedPath)
                context.recordFileRead(path)
            }
            return content
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }
    }

    /// Returns an error message if the path is restricted, or nil if allowed.
    static func checkPathRestriction(_ path: String) -> String? {
        // Resolve relative paths AND symlinks so neither "../../../.ssh" nor symlink indirection can bypass checks
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let home = NSHomeDirectory()

        // Block sensitive credential directories.
        // Lowercase both sides: APFS is case-insensitive so /Users/FOO/.SSH bypasses a case-sensitive check.
        let sensitiveDirs = [".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker"]
        for dir in sensitiveDirs {
            let dirPath = (home as NSString).appendingPathComponent(dir)
            if resolved.lowercased().hasPrefix(dirPath.lowercased()) {
                return "BLOCKED: Cannot read sensitive credential path '\(path)'"
            }
        }

        // Block system credential files
        let systemCredentials = ["/etc/shadow", "/etc/master.passwd", "/private/etc/master.passwd"]
        for cred in systemCredentials {
            if resolved.lowercased() == cred.lowercased() || resolved.lowercased().hasPrefix(cred.lowercased()) {
                return "BLOCKED: Cannot read system credential file '\(path)'"
            }
        }

        return nil
    }
}
