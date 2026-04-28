import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `GrepTool`. Covers both output modes (`files_with_matches` default and
/// `content`), the optional `glob` filter (basename vs path-style), invalid regex rejection,
/// path validation, and that hidden directories + sensitive credential paths are skipped.
@Suite("GrepTool")
struct GrepToolTests {

    /// Helper: lay out a small fixture with a few Swift / TS / hidden / unmatching files.
    private func makeFixture() throws -> TempDir {
        let dir = TempDir()
        _ = try dir.write("import Foundation\nlet x = 1\n", to: "a.swift")
        _ = try dir.write("import Foundation\nlet y = 2\n", to: "deep/b.swift")
        _ = try dir.write("// no swift import here\n", to: "c.swift")
        _ = try dir.write("export const x = 1;\n", to: "page.ts")
        _ = try dir.write("import nothing of note\n", to: ".hidden/secret.swift")
        return dir
    }

    @Test("files_with_matches mode (default) returns one path per matching file")
    func filesWithMatchesDefault() async throws {
        let dir = try makeFixture()
        defer { dir.cleanup() }

        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("import Foundation"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make(agentRole: .brown)
        )

        #expect(result.succeeded)
        let lines = result.output.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(result.output.contains("a.swift"))
        #expect(result.output.contains("b.swift"))
        #expect(!result.output.contains("c.swift"))
        #expect(!result.output.contains(".hidden"))
    }

    @Test("content mode returns file:line:content lines")
    func contentMode() async throws {
        let dir = try makeFixture()
        defer { dir.cleanup() }

        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("import Foundation"),
                "path": .string(dir.path),
                "output_mode": .string("content")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )

        #expect(result.succeeded)
        let lines = result.output.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        for line in lines {
            // file:line_number:content — the "1" is the line number we wrote.
            #expect(line.contains(":1:import Foundation"))
        }
    }

    @Test("invalid output_mode is rejected")
    func invalidOutputModeRejected() async throws {
        let dir = try makeFixture()
        defer { dir.cleanup() }

        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("anything"),
                "path": .string(dir.path),
                "output_mode": .string("bogus")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("output_mode"))
    }

    @Test("glob without slash filters by basename")
    func globFiltersByBasename() async throws {
        let dir = try makeFixture()
        defer { dir.cleanup() }

        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("import"),
                "path": .string(dir.path),
                "glob": .string("*.swift")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(result.succeeded)
        // Both .swift files with imports match; .ts file is filtered out.
        #expect(result.output.contains("a.swift"))
        #expect(result.output.contains("b.swift"))
        #expect(!result.output.contains("page.ts"))
    }

    @Test("brace-alternation glob matches multiple extensions")
    func braceAlternationGlob() async throws {
        let dir = try makeFixture()
        defer { dir.cleanup() }

        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("."),
                "path": .string(dir.path),
                "glob": .string("*.{ts,swift}")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(result.succeeded)
        #expect(result.output.contains("page.ts"))
        #expect(result.output.contains("a.swift"))
    }

    @Test("invalid regex returns failure")
    func invalidRegexRejected() async throws {
        let dir = try makeFixture()
        defer { dir.cleanup() }

        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("[unclosed"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("Invalid regex"))
    }

    @Test("relative path is rejected")
    func relativePathRejected() async throws {
        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("anything"),
                "path": .string("relative/dir")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("absolute"))
    }

    @Test("missing path returns failure (file or directory — same path-not-exist branch)")
    func missingPathFails() async throws {
        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("anything"),
                "path": .string("/tmp/does-not-exist-\(UUID().uuidString)")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("does not exist"))
    }

    @Test("no matches is success with explanatory output")
    func noMatchesIsSuccess() async throws {
        let dir = try makeFixture()
        defer { dir.cleanup() }

        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("zzz_definitely_not_present"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(result.succeeded)
        #expect(result.output.contains("No files matched"))
    }

    @Test("path may be a single file (not just a directory)")
    func singleFilePath() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("alpha\nlet x = 1\nbeta\nlet y = 2\n", to: "single.swift")

        // files_with_matches mode
        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("^let "),
                "path": .string(path)
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(result.succeeded)
        #expect(result.output.contains("single.swift"))

        // content mode returns line-numbered matches from the single file
        let contentResult = try await GrepTool().execute(
            arguments: [
                "pattern": .string("^let "),
                "path": .string(path),
                "output_mode": .string("content")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(contentResult.succeeded)
        #expect(contentResult.output.contains(":2:let x = 1"))
        #expect(contentResult.output.contains(":4:let y = 2"))
    }

    @Test("`..` in glob is rejected")
    func dotDotInGlobRejected() async throws {
        let dir = try makeFixture()
        defer { dir.cleanup() }

        let result = try await GrepTool().execute(
            arguments: [
                "pattern": .string("anything"),
                "path": .string(dir.path),
                "glob": .string("../*.swift")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("path traversal"))
    }
}
