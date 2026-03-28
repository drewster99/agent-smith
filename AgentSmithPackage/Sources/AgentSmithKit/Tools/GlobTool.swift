import Foundation

/// Fast file pattern matching tool.
///
/// Supports glob patterns like `**/*.swift` or `src/**/*.ts`.
/// Returns matching file paths sorted by modification time (most recent first).
public struct GlobTool: AgentTool {
    public let name = "glob"
    public let toolDescription = "Find files matching a glob pattern. Supports *, **, ?, and {a,b} patterns. Returns matching file paths sorted by modification time (most recent first). Use instead of find or ls for file discovery."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "a list of matching file paths")
        default:
            return toolDescription
        }
    }

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "pattern": .dictionary([
                "type": .string("string"),
                "description": .string("The glob pattern to match files against (e.g. **/*.swift, src/**/*.ts, **/test*).")
            ]),
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("The absolute directory path to search in. Must start with /.")
            ])
        ]),
        "required": .array([.string("pattern"), .string("path")])
    ]

    /// Maximum number of results to return.
    private static let maxResults = 500

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let pattern) = arguments["pattern"] else {
            throw ToolCallError.missingRequiredArgument("pattern")
        }
        guard case .string(let path) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }

        // Validate absolute path.
        guard path.hasPrefix("/") else {
            return "Error: path must be absolute (start with /). Got: \(path)"
        }

        // Reject path traversal in pattern.
        guard !pattern.contains("..") else {
            return "Error: Pattern must not contain '..' (path traversal)."
        }

        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: path)
        let resolvedBase = baseURL.resolvingSymlinksInPath().path

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedBase, isDirectory: &isDir), isDir.boolValue else {
            return "Error: Directory does not exist: \(path)"
        }

        // Convert glob pattern to regex.
        let regex: NSRegularExpression
        do {
            let regexPattern = Self.globToRegex(pattern)
            regex = try NSRegularExpression(pattern: "^\(regexPattern)$")
        } catch {
            return "Error: Invalid glob pattern '\(pattern)': \(error.localizedDescription)"
        }

        // Enumerate all files recursively.
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: resolvedBase),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "Error: Unable to enumerate directory: \(path)"
        }

        // Collect all URLs from the enumerator synchronously to avoid
        // async-context restrictions on NSDirectoryEnumerator.makeIterator().
        var allURLs: [URL] = []
        while let obj = enumerator.nextObject() {
            if let fileURL = obj as? URL {
                allURLs.append(fileURL)
            }
        }

        var matches: [(path: String, modDate: Date)] = []

        for fileURL in allURLs {
            // Only match regular files.
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let resolvedFile = fileURL.resolvingSymlinksInPath().path

            // Security: ensure the resolved path is still under the base directory.
            guard resolvedFile.hasPrefix(resolvedBase + "/") || resolvedFile == resolvedBase else {
                continue
            }

            // Compute relative path for matching.
            let relativePath: String
            if resolvedFile.hasPrefix(resolvedBase + "/") {
                relativePath = String(resolvedFile.dropFirst(resolvedBase.count + 1))
            } else {
                continue
            }

            // Match against the glob pattern.
            let range = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
            if regex.firstMatch(in: relativePath, range: range) != nil {
                let modDate = resourceValues.contentModificationDate ?? Date.distantPast
                matches.append((path: fileURL.path, modDate: modDate))
            }
        }

        // Sort by modification time, most recent first.
        matches.sort { $0.modDate > $1.modDate }

        if matches.isEmpty {
            return "No files matched the pattern '\(pattern)' in \(path)."
        }

        let truncated = matches.count > Self.maxResults
        let resultPaths = matches.prefix(Self.maxResults).map(\.path)
        var output = resultPaths.joined(separator: "\n")

        if truncated {
            output += "\n\n[Results truncated: showing \(Self.maxResults) of \(matches.count) matches]"
        }

        return output
    }

    // MARK: - Glob to Regex Conversion

    /// Converts a glob pattern to a regex pattern string.
    ///
    /// Supports:
    /// - `**` — matches any number of path segments (including zero)
    /// - `*` — matches any characters except `/`
    /// - `?` — matches a single character except `/`
    /// - `{a,b}` — alternation (brace expansion)
    /// - All other regex-special characters are escaped
    static func globToRegex(_ glob: String) -> String {
        var result = ""
        var i = glob.startIndex

        while i < glob.endIndex {
            let c = glob[i]

            if c == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex && glob[next] == "*" {
                    // ** — match any path segments
                    let afterStars = glob.index(after: next)
                    if afterStars < glob.endIndex && glob[afterStars] == "/" {
                        // **/ — zero or more path segments followed by /
                        result += "(.+/)?"
                        i = glob.index(after: afterStars)
                    } else {
                        // ** at end or before non-/ — match everything
                        result += ".*"
                        i = afterStars
                    }
                } else {
                    // Single * — match within a path segment
                    result += "[^/]*"
                    i = next
                }
            } else if c == "?" {
                result += "[^/]"
                i = glob.index(after: i)
            } else if c == "{" {
                // Brace expansion: {a,b,c} → (a|b|c)
                if let closeIdx = glob[i...].firstIndex(of: "}") {
                    let inner = glob[glob.index(after: i)..<closeIdx]
                    let alternatives = inner.split(separator: ",").map { Self.globToRegex(String($0)) }
                    result += "(\(alternatives.joined(separator: "|")))"
                    i = glob.index(after: closeIdx)
                } else {
                    // No closing brace — treat as literal
                    result += "\\{"
                    i = glob.index(after: i)
                }
            } else if c == "}" {
                // Unmatched closing brace — treat as literal
                result += "\\}"
                i = glob.index(after: i)
            } else {
                // Escape regex-special characters.
                let special: Set<Character> = [".", "+", "^", "$", "|", "(", ")", "[", "]", "\\"]
                if special.contains(c) {
                    result += "\\\(c)"
                } else {
                    result.append(c)
                }
                i = glob.index(after: i)
            }
        }

        return result
    }
}
