import Foundation

/// Performs exact string replacements in files.
///
/// Requires that the file was previously read via `file_read` in the current session.
/// Reuses `FileWriteTool.checkPathRestriction` for safety validation.
public struct FileEditTool: AgentTool {
    public let name = "file_edit"
    public let toolDescription = "Perform an exact string replacement in a file. You must read the file first with file_read before editing it. The old_string must be unique in the file unless replace_all is true."

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
            "file_path": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute path to the file to modify. Must start with /.")
            ]),
            "old_string": .dictionary([
                "type": .string("string"),
                "description": .string("The exact text to find and replace. Must match the file content exactly, including indentation.")
            ]),
            "new_string": .dictionary([
                "type": .string("string"),
                "description": .string("The replacement text. Must be different from old_string.")
            ]),
            "replace_all": .dictionary([
                "type": .string("boolean"),
                "description": .string("If true, replace all occurrences of old_string. If false (default), old_string must appear exactly once.")
            ])
        ]),
        "required": .array([.string("file_path"), .string("old_string"), .string("new_string")])
    ]

    /// Maximum file size in characters for editing.
    private static let maxCharacters = 250_000

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let filePath) = arguments["file_path"] else {
            throw ToolCallError.missingRequiredArgument("file_path")
        }
        guard case .string(let oldString) = arguments["old_string"] else {
            throw ToolCallError.missingRequiredArgument("old_string")
        }
        guard case .string(let newString) = arguments["new_string"] else {
            throw ToolCallError.missingRequiredArgument("new_string")
        }

        let replaceAll: Bool
        if case .bool(let flag) = arguments["replace_all"] {
            replaceAll = flag
        } else {
            replaceAll = false
        }

        // Validate absolute path.
        guard filePath.hasPrefix("/") else {
            return "Error: file_path must be absolute (start with /). Got: \(filePath)"
        }

        // Verify the file was read this session.
        let url = URL(fileURLWithPath: filePath)
        let resolvedPath = url.resolvingSymlinksInPath().path
        guard context.hasFileBeenRead(filePath) || context.hasFileBeenRead(resolvedPath) else {
            return "Error: You must read a file with file_read before editing it."
        }

        // Safety check — reuse FileWriteTool's path restriction logic.
        if let rejection = FileWriteTool.checkPathRestriction(resolvedPath: resolvedPath) {
            return rejection
        }

        let fm = FileManager.default

        // Check file exists.
        guard fm.fileExists(atPath: resolvedPath) else {
            return "Error: File does not exist: \(filePath)"
        }

        // Check for hard links and file size before reading.
        do {
            let attrs = try fm.attributesOfItem(atPath: resolvedPath)
            if let linkCount = attrs[.referenceCount] as? Int, linkCount > 1 {
                return "BLOCKED: File '\(filePath)' has \(linkCount) hard links. Editing would affect all linked paths."
            }
            if let fileSize = attrs[.size] as? UInt64, fileSize > Self.maxCharacters {
                return "Error: File is too large to edit (\(fileSize) bytes, maximum is \(Self.maxCharacters))."
            }
        } catch {
            return "Error checking file attributes: \(error.localizedDescription)"
        }

        // Validate old_string != new_string.
        guard oldString != newString else {
            return "Error: old_string and new_string are identical. Nothing to change."
        }

        // Read file content.
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }

        guard content.count <= Self.maxCharacters else {
            return "Error: File is too large to edit (\(content.count) characters, maximum is \(Self.maxCharacters))."
        }

        // Count occurrences.
        let occurrences = content.occurrenceCount(of: oldString)

        guard occurrences > 0 else {
            return "Error: old_string not found in the file. Make sure it matches the file content exactly, including whitespace and indentation."
        }

        if !replaceAll && occurrences > 1 {
            return "Error: old_string appears \(occurrences) times in the file. Provide more surrounding context to make it unique, or set replace_all to true."
        }

        // Perform replacement.
        let newContent: String
        if replaceAll {
            newContent = content.replacingOccurrences(of: oldString, with: newString)
        } else {
            // Replace only the first (and only) occurrence.
            guard let range = content.range(of: oldString) else {
                return "Error: old_string not found in the file."
            }
            newContent = content.replacingCharacters(in: range, with: newString)
        }

        // Write atomically.
        let resolvedURL = URL(fileURLWithPath: resolvedPath)
        do {
            try newContent.write(to: resolvedURL, atomically: true, encoding: .utf8)
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }

        if replaceAll {
            return "Successfully replaced \(occurrences) occurrence\(occurrences == 1 ? "" : "s") in \(filePath)."
        } else {
            return "Successfully replaced 1 occurrence in \(filePath)."
        }
    }
}

// MARK: - String helpers

private extension String {
    /// Counts non-overlapping occurrences of `target` in this string.
    func occurrenceCount(of target: String) -> Int {
        guard !target.isEmpty else { return 0 }
        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = self.range(of: target, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }
}
