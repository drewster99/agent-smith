import Foundation

/// Shared hard blocklist for shell command validation, used by both ShellTool and BashTool.
public enum CommandBlocklist {
    /// Patterns that are unconditionally blocked, regardless of Jones.
    /// Compared with ALL whitespace stripped so no spacing trick can bypass them.
    static let blockedPatterns: [String] = [
        "rm -rf /",
        "rm -rf /*",
        "rm -rf ~",
        "rm -rf ~/*",
        "rm -rf $home",
        "rm -rf \"$home\"",
        "rm -Rf /",
        "rm -Rf /*",
        "rm -r -f /",
        "rm -r -f /*",
        "mkfs",
        "dd if=",
        ":(){:|:&};:",          // fork bomb
        "chmod -R 777 /",
        "chown -R root",
        "wget|sh",
        "curl|sh",
        "curl|bash",
        "wget|bash",
        "> /dev/sda",
        "> /dev/disk",
        "shutdown",
        "reboot",
        "halt",
        "init 0",
        "init 6",
        "launchctl unload",
        "base64 -d|sh",
        "base64 -d|bash",
        "base64 --decode|sh",
        "base64 --decode|bash",
        "find / -delete",
        "find / -exec rm",
    ]

    /// Additional patterns checked against the raw (non-stripped) command.
    /// These catch indirection techniques that could bypass the primary blocklist.
    static let rawBlockedPatterns: [String] = [
        "eval ",
        "bash -c ",
        "sh -c ",
        "zsh -c ",
    ]

    /// Sensitive paths that should not be accessible via shell commands.
    static let sensitiveHomeDirs = [".ssh", ".gnupg", ".aws", ".kube", ".config/gcloud", ".docker"]
    static let sensitiveSystemPaths = ["/etc/shadow", "/etc/master.passwd", "/private/etc/master.passwd"]

    /// Strips ALL whitespace and lowercases for comparison.
    static func stripForComparison(_ input: String) -> String {
        String(input.lowercased().filter { !$0.isWhitespace })
    }

    /// Returns a rejection message if the command references sensitive credential paths, nil otherwise.
    static func checkSensitivePaths(_ command: String) -> String? {
        let home = NSHomeDirectory()
        let lowered = command.lowercased()
        let homeLower = home.lowercased()

        let expanded = lowered
            .replacingOccurrences(of: "~", with: homeLower)
            .replacingOccurrences(of: "$home", with: homeLower)
            .replacingOccurrences(of: "${home}", with: homeLower)

        for dir in sensitiveHomeDirs {
            let dirLower = dir.lowercased()
            let dirPath = (homeLower as NSString).appendingPathComponent(dirLower)
            let patterns = [dirPath, "~/\(dirLower)", "$home/\(dirLower)", "${home}/\(dirLower)"]
            for pattern in patterns where expanded.contains(pattern) || lowered.contains(pattern) {
                return "BLOCKED: Command references sensitive credential path '\(dir)'"
            }
        }

        for path in sensitiveSystemPaths where lowered.contains(path.lowercased()) {
            return "BLOCKED: Command references sensitive system credential file '\(path)'"
        }

        return nil
    }

    /// Validates a command against all blocklists. Returns a rejection message or nil if safe.
    static func validate(_ command: String) -> String? {
        // Check sensitive paths
        if let rejection = checkSensitivePaths(command) {
            return rejection
        }

        // Hard blocklist — strip all whitespace before comparing
        let stripped = stripForComparison(command)
        for pattern in blockedPatterns {
            let strippedPattern = stripForComparison(pattern)
            if stripped.contains(strippedPattern) {
                return "BLOCKED: Command rejected by safety blocklist — '\(command)' matches blocked pattern '\(pattern)'"
            }
        }

        // Indirection patterns — checked against raw lowercased command
        let lowered = command.lowercased()
        for pattern in rawBlockedPatterns {
            if lowered.contains(pattern) {
                return "BLOCKED: Command uses indirection '\(pattern.trimmingCharacters(in: .whitespaces))' — execute the inner command directly instead"
            }
        }

        return nil
    }
}
