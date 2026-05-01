import Foundation

/// Fast file pattern matching tool.
///
/// Supports glob patterns like `**/*.swift` or `src/**/*.ts`.
/// Returns matching file paths sorted by modification time (most recent first).
struct GlobTool: AgentTool {
    let name = "glob"
    let toolDescription = "Find files matching a glob pattern. Supports *, **, ?, and {a,b} patterns. Returns matching file paths sorted by modification time (most recent first). Hidden files (dotfiles) are skipped by default. Use instead of find or ls for file discovery."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "a list of matching file paths")
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "pattern": .dictionary([
                "type": .string("string"),
                "description": .string("The glob pattern to match files against (e.g. **/*.swift, src/**/*.ts, **/test*).")
            ]),
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("The absolute directory path to search in. Must start with / or ~/.")
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

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let pattern) = arguments["pattern"] else {
            throw ToolCallError.missingRequiredArgument("pattern")
        }
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let path = (rawPath as NSString).expandingTildeInPath

        // Validate absolute path.
        guard path.hasPrefix("/") else {
            return .failure("Error: path must be absolute (start with /). Got: \(path)")
        }

        // Reject path traversal in pattern.
        guard !pattern.contains("..") else {
            return .failure("Error: Pattern must not contain '..' (path traversal).")
        }

        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: path)
        let resolvedBase = baseURL.resolvingSymlinksInPath().path

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedBase, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Error: Directory does not exist: \(path)")
        }

        // Convert glob pattern to regex.
        let regex: NSRegularExpression
        do {
            let regexPattern = Self.globToRegex(pattern)
            regex = try NSRegularExpression(pattern: "^\(regexPattern)$")
        } catch {
            return .failure("Error: Invalid glob pattern '\(pattern)': \(error.localizedDescription)")
        }

        // Enumerate all files recursively.
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: resolvedBase),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .failure("Error: Unable to enumerate directory: \(path)")
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
            // Only match regular files. Skip files whose metadata can't be read
            // (e.g., permission denied) — these are not actionable glob results.
            let resourceValues: URLResourceValues
            do {
                resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            } catch {
                continue
            }
            guard resourceValues.isRegularFile == true else {
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
            // No matches is not a failure — the pattern just didn't hit. Successful empty result.
            return .success("No files matched the pattern '\(pattern)' in \(path).")
        }

        let truncated = matches.count > Self.maxResults
        let resultPaths = matches.prefix(Self.maxResults).map(\.path)
        var output = resultPaths.joined(separator: "\n")

        if truncated {
            output += "\n\n[Results truncated: showing \(Self.maxResults) of \(matches.count) matches]"
        }

        return .success(output)
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
                        result += "(.*/)?"
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
                // Brace expansion: {a,b,c} → (a|b|c). Supports nesting via depth tracking.
                if let closeIdx = Self.findMatchingBrace(in: glob, from: i) {
                    let inner = glob[glob.index(after: i)..<closeIdx]
                    let alternatives = Self.splitBraceAlternatives(inner).map { Self.globToRegex(String($0)) }
                    result += "(\(alternatives.joined(separator: "|")))"
                    i = glob.index(after: closeIdx)
                } else {
                    // No matching closing brace — treat as literal
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

    /// Finds the matching `}` for a `{` at `openIdx`, respecting nested braces.
    /// Returns the index of the matching `}`, or `nil` if unmatched.
    private static func findMatchingBrace(in str: String, from openIdx: String.Index) -> String.Index? {
        var depth = 0
        var idx = openIdx
        while idx < str.endIndex {
            if str[idx] == "{" {
                depth += 1
            } else if str[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    return idx
                }
            }
            idx = str.index(after: idx)
        }
        return nil
    }

    /// Splits brace content by commas at the top level only (depth 0),
    /// so `{a,{b,c}}` splits into `["a", "{b,c}"]` rather than `["a", "{b", "c}"]`.
    private static func splitBraceAlternatives(_ content: Substring) -> [Substring] {
        var alternatives: [Substring] = []
        var depth = 0
        var segmentStart = content.startIndex

        for idx in content.indices {
            let c = content[idx]
            if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
            } else if c == "," && depth == 0 {
                alternatives.append(content[segmentStart..<idx])
                segmentStart = content.index(after: idx)
            }
        }
        alternatives.append(content[segmentStart...])
        return alternatives
    }
}
