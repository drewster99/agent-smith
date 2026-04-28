import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `FileReadTool`. Covers happy-path text reads with `cat -n` line numbering,
/// `offset`/`limit` slicing, missing-file errors, path-restriction guard, and that
/// successful reads as Brown record the path with the file-read tracker (so subsequent
/// `file_write` calls on the same path are allowed).
@Suite("FileReadTool")
struct FileReadToolTests {

    @Test("reads a text file with cat -n line numbering")
    func readsTextWithLineNumbers() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("alpha\nbeta\ngamma\n", to: "fixture.txt")

        let result = try await FileReadTool().execute(
            arguments: ["path": .string(path)],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        // cat -n format: 6-char right-justified line number, two spaces, content.
        #expect(result.output.contains("     1  alpha"))
        #expect(result.output.contains("     2  beta"))
        #expect(result.output.contains("     3  gamma"))
    }

    @Test("offset and limit slice the file")
    func offsetAndLimitSliceFile() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let body = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let path = try dir.write(body, to: "fixture.txt")

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "offset": .int(3),
                "limit": .int(2)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(result.output.contains("     3  line 3"))
        #expect(result.output.contains("     4  line 4"))
        #expect(!result.output.contains("line 5"))
        // Tail note that more remains.
        #expect(result.output.contains("[File has 10 total lines"))
    }

    @Test("offset past end of file returns failure")
    func offsetPastEndIsFailure() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("only one line\n", to: "fixture.txt")

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "offset": .int(100)
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("offset"))
    }

    @Test("missing file returns failure")
    func missingFileFailure() async throws {
        let result = try await FileReadTool().execute(
            arguments: ["path": .string("/tmp/agent-smith-tests/does-not-exist-\(UUID().uuidString).txt")],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
    }

    @Test("blocks reads of ~/.ssh paths")
    func blocksSshReads() {
        let home = NSHomeDirectory()
        let blocked = (home as NSString).appendingPathComponent(".ssh/id_rsa")
        let result = FileReadTool.checkPathRestriction(blocked)
        #expect(result?.hasPrefix("BLOCKED") == true)
    }

    @Test("blocks /etc/master.passwd")
    func blocksSystemCredentials() {
        let result = FileReadTool.checkPathRestriction("/etc/master.passwd")
        #expect(result?.hasPrefix("BLOCKED") == true)
    }

    @Test("Brown's read records the path with the tracker")
    func brownReadRecordsPath() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("hi", to: "fixture.txt")

        let tracker = TestToolContext.FileReadTrackerStub()
        _ = try await FileReadTool().execute(
            arguments: ["path": .string(path)],
            context: TestToolContext.make(agentRole: .brown, fileReadTracker: tracker)
        )

        #expect(tracker.has(path))
    }

    @Test("Smith and Jones reads do not record (only Brown's reads gate file_write)")
    func nonBrownReadsDontRecord() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("hi", to: "fixture.txt")

        for role in [AgentRole.smith, .jones] {
            let tracker = TestToolContext.FileReadTrackerStub()
            _ = try await FileReadTool().execute(
                arguments: ["path": .string(path)],
                context: TestToolContext.make(agentRole: role, fileReadTracker: tracker)
            )
            #expect(tracker.allRecorded.isEmpty, "role \(role) should not record reads")
        }
    }

    @Test("missing path argument throws")
    func missingPathArgumentThrows() async throws {
        do {
            _ = try await FileReadTool().execute(
                arguments: [:],
                context: TestToolContext.make()
            )
            Issue.record("expected throw")
        } catch ToolCallError.missingRequiredArgument(let name) {
            #expect(name == "path")
        }
    }
}
