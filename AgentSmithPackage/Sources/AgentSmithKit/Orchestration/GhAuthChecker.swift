import Foundation

/// Runs `gh auth status` once at Brown spawn time so Brown's `gh` tool description can include
/// the verified auth state. Brown has historically refused GitHub work claiming "I don't have
/// access" or "I'm not authenticated" even when `gh` was logged in — surfacing the actual auth
/// output in the tool description short-circuits that confusion.
enum GhAuthChecker {
    static func authStatus() async -> String {
        do {
            let result = try await ProcessRunner.run(
                executable: "/bin/bash",
                arguments: ["-l", "-c", "gh auth status"],
                workingDirectory: nil,
                timeout: 30
            )
            if result.timedOut {
                return "Could not capture `gh auth status` (timed out after 30s)."
            }
            if result.output.isEmpty {
                return "Could not capture `gh auth status` (no output, exit \(result.exitCode))."
            }
            return result.output
        } catch {
            return "Could not run `gh auth status`: \(error.localizedDescription). The `gh` tool may still work if `gh` is on PATH; treat absence of output as inconclusive, not as a failure."
        }
    }
}
