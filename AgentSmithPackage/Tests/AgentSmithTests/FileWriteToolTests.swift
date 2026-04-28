import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `FileWriteTool`. Covers new-file creation (no prior read needed), the
/// must-have-read-before-overwrite guard, parent-directory creation, the relative-path
/// rejection, and the path-restriction list (system dirs, home credentials, shell rc files).
@Suite("FileWriteTool")
struct FileWriteToolTests {

    @Test("creates a new file freely (no prior read required)")
    func createsNewFile() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let target = "\(dir.path)/new.txt"

        let result = try await FileWriteTool().execute(
            arguments: [
                "path": .string(target),
                "content": .string("hello\n")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )

        #expect(result.succeeded)
        let written = try String(contentsOf: URL(fileURLWithPath: target), encoding: .utf8)
        #expect(written == "hello\n")
    }

    @Test("creates intermediate directories")
    func createsIntermediateDirs() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let target = "\(dir.path)/a/b/c/deep.txt"

        let result = try await FileWriteTool().execute(
            arguments: [
                "path": .string(target),
                "content": .string("x")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(result.succeeded)
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test("overwriting an existing file requires a prior file_read")
    func overwriteRequiresPriorRead() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("original\n", to: "existing.txt")

        // First attempt: no prior read recorded → blocked.
        let blocked = try await FileWriteTool().execute(
            arguments: [
                "path": .string(path),
                "content": .string("new\n")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!blocked.succeeded)
        #expect(blocked.output.contains("must read it"))

        // Second attempt: tracker says we read it → allowed.
        let tracker = TestToolContext.FileReadTrackerStub()
        tracker.record(path)
        let allowed = try await FileWriteTool().execute(
            arguments: [
                "path": .string(path),
                "content": .string("new\n")
            ],
            context: TestToolContext.make(agentRole: .brown, fileReadTracker: tracker)
        )
        #expect(allowed.succeeded)
        let written = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(written == "new\n")
    }

    @Test("relative paths are rejected")
    func relativePathRejected() async throws {
        let result = try await FileWriteTool().execute(
            arguments: [
                "path": .string("relative/path.txt"),
                "content": .string("x")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("BLOCKED"))
    }

    @Test("system paths are blocked")
    func systemPathsBlocked() {
        // checkPathRestriction is invoked with already-resolved paths, so we pass them directly.
        for path in ["/etc/hosts", "/System/Library/foo", "/usr/bin/ls", "/private/var/foo"] {
            #expect(
                FileWriteTool.checkPathRestriction(resolvedPath: path)?.hasPrefix("BLOCKED") == true,
                "expected \(path) to be blocked"
            )
        }
    }

    @Test("home credential dirs are blocked")
    func homeCredentialsBlocked() {
        let home = NSHomeDirectory()
        let blocked = (home as NSString).appendingPathComponent(".ssh/config")
        #expect(FileWriteTool.checkPathRestriction(resolvedPath: blocked)?.hasPrefix("BLOCKED") == true)
    }

    @Test("shell rc files are blocked")
    func shellRcFilesBlocked() {
        let home = NSHomeDirectory()
        for name in [".zshrc", ".bashrc", ".bash_profile", ".profile"] {
            let path = (home as NSString).appendingPathComponent(name)
            #expect(
                FileWriteTool.checkPathRestriction(resolvedPath: path)?.hasPrefix("BLOCKED") == true,
                "expected \(name) to be blocked"
            )
        }
    }

    @Test("regular paths inside temp dir are allowed by checkPathRestriction")
    func ordinaryPathsAllowed() {
        let dir = TempDir()
        defer { dir.cleanup() }
        #expect(FileWriteTool.checkPathRestriction(resolvedPath: "\(dir.path)/file.txt") == nil)
    }
}
