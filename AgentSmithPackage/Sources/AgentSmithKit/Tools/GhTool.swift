import Foundation

/// Brown tool: runs the GitHub CLI (`gh`) with arbitrary args. Internally invokes
/// `/bin/bash -l -c "gh <args>"` so `~`, `$VAR`, pipes, and redirection all work as in a normal
/// shell. The tool's description includes the captured `gh auth status` output from Brown's
/// spawn so the model has direct evidence that authentication is in place — without this,
/// gpt-style models routinely refuse GitHub work claiming "I don't have access."
public struct GhTool: AgentTool {
    public let name = "gh"
    private let authStatusSnapshot: String

    /// Substrings rejected before the args reach bash. Naive (not quote-aware) — false
    /// positives just make the model retry with different phrasing, while a false negative
    /// would let the forbidden sequence through to the shell. We optimize for the latter.
    /// `$(` covers POSIX command substitution (functionally equivalent to backticks).
    static let forbiddenSequences: [String] = [
        "&&", "||", "<<<", "$(", "`", ";"
    ]

    /// Returns the first forbidden sequence found in `args`, or nil if the args are clean.
    /// Order matches `forbiddenSequences`; multi-char sequences are listed first so that, e.g.,
    /// `&&` is reported as `&&` rather than as the single `&` that isn't actually forbidden.
    static func firstForbiddenSequence(in args: String) -> String? {
        for needle in forbiddenSequences where args.contains(needle) {
            return needle
        }
        return nil
    }

    public init(authStatusSnapshot: String = "(auth status was not captured for this spawn)") {
        self.authStatusSnapshot = authStatusSnapshot
    }

    public var toolDescription: String {
        """
        Run a GitHub CLI command. Args are passed through `/bin/bash -l -c "gh <args>"`. \
        ALLOWED shell features: `~` expansion, `$VAR` expansion, pipes (`|`), redirection \
        (`>`, `>>`, `<`, `2>`), single `&`. \
        BLOCKED (call will be refused before bash sees it): `;`, `&&`, `||`, `<<<`, backticks, \
        and `$(...)` command substitution. The block is naive substring matching — it triggers \
        even inside quoted strings, so prefer plain identifiers. If you need to chain commands, \
        issue separate gh calls instead. \
        You ARE authenticated to GitHub via `gh` — the `gh auth status` snapshot below was \
        captured at the start of this task and is verified. Do NOT try to "configure auth", \
        "log in", or run `gh auth login`. Just use `gh` directly.

        gh auth status (captured at task start):
        \(authStatusSnapshot)

        Examples (pass to the `args` parameter, no leading `gh`):
        - "repo view drewster99/agent-smith"
        - "issue list --json number,title --jq '.[].number'"
        - "pr create --title 'Fix X' --body 'Closes #123'"
        - "release upload v1.0 ~/Downloads/asset.zip"
        """
    }

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                BrownBehavior.approvalGateNote(outcome: "the gh command output") +
                BrownBehavior.terminationWarning
        default:
            return toolDescription
        }
    }

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "args": .dictionary([
                "type": .string("string"),
                "description": .string("Arguments to pass to the gh CLI. Do NOT include the leading `gh` — pass everything that would come after it (e.g. \"repo view drewster99/foo\").")
            ]),
            "workingDirectory": .dictionary([
                "type": .string("string"),
                "description": .string("Optional working directory for the command (e.g. when running gh inside a clone).")
            ]),
            "timeout": .dictionary([
                "type": .string("integer"),
                "description": .string("Timeout in seconds. Defaults to 300.")
            ])
        ]),
        "required": .array([.string("args")])
    ]

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> String {
        guard case .string(let args) = arguments["args"] else {
            throw ToolCallError.missingRequiredArgument("args")
        }

        if let forbidden = Self.firstForbiddenSequence(in: args) {
            return """
                Refused: gh args contain forbidden shell sequence '\(forbidden)'. \
                The gh tool allows ~ expansion, $VAR expansion, pipes, and redirection, \
                but blocks ; && || <<< backticks and $(...) — including when they appear \
                inside quoted strings. Reformulate the call without these sequences \
                (e.g. run two gh calls separately instead of chaining with ;).
                """
        }

        let timeoutSeconds: Int
        if case .int(let t) = arguments["timeout"] {
            timeoutSeconds = t
        } else {
            timeoutSeconds = 300
        }

        let workingDir: String?
        if case .string(let dir) = arguments["workingDirectory"] {
            workingDir = dir
        } else {
            workingDir = nil
        }

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-l", "-c", "gh \(args)"],
            workingDirectory: workingDir,
            timeout: TimeInterval(timeoutSeconds)
        )

        if result.timedOut {
            return "Command timed out after \(timeoutSeconds) seconds\n\(result.output)"
        } else if result.exitCode == 0 {
            return result.output.isEmpty ? "(no output)" : result.output
        } else {
            return "Exit code \(result.exitCode)\n\(result.output)"
        }
    }
}
