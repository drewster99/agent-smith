import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `GlobTool`. The pure regex-translation logic is exercised directly via
/// `GlobTool.globToRegex`; the `execute(...)` paths run against a per-test temp directory
/// so the file-system enumeration is deterministic and self-cleaning.
@Suite("GlobTool")
struct GlobToolTests {

    // MARK: - globToRegex (pure)

    @Test("`**` followed by `/` becomes optional path-prefix")
    func doubleStarSlashTranslatesToOptionalPrefix() {
        // Anchored externally with ^...$; the (.*/)? prefix means "zero or more segments".
        #expect(GlobTool.globToRegex("**/Foo.swift") == "(.*/)?Foo\\.swift")
    }

    @Test("single `*` matches within a path segment")
    func singleStarTranslatesToNonSlashRun() {
        #expect(GlobTool.globToRegex("*.swift") == "[^/]*\\.swift")
    }

    @Test("`?` matches a single non-slash character")
    func questionMarkTranslatesToNonSlashSingle() {
        #expect(GlobTool.globToRegex("file?.swift") == "file[^/]\\.swift")
    }

    @Test("brace alternation expands to a regex group")
    func braceExpansion() {
        // Each brace alternative is itself run through globToRegex, but plain literals
        // like "ts" have no glob metacharacters so they translate verbatim. The leading
        // `[^/]*\.` comes from the `*.` outside the braces.
        #expect(GlobTool.globToRegex("*.{ts,tsx}") == "[^/]*\\.(ts|tsx)")
    }

    @Test("regex-special characters are escaped")
    func specialCharsEscaped() {
        #expect(GlobTool.globToRegex("a.b+c") == "a\\.b\\+c")
        #expect(GlobTool.globToRegex("[x]") == "\\[x\\]")
    }

    // MARK: - execute()

    @Test("matches files at any depth")
    func matchesAtAnyDepth() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "InspectorView.swift")
        _ = try dir.write("b", to: "sub/InspectorView.swift")
        _ = try dir.write("c", to: "deep/sub/InspectorView.swift")
        _ = try dir.write("noise", to: "deep/Other.swift")

        let result = try await GlobTool().execute(
            arguments: [
                "pattern": .string("**/InspectorView.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(result.output.contains("InspectorView.swift"))
        #expect(!result.output.contains("Other.swift"))
        // Three matches, on three separate lines.
        let lines = result.output.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
    }

    @Test("no matches is a successful empty result, not a failure")
    func noMatchesReturnsSuccess() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("x", to: "a.txt")

        let result = try await GlobTool().execute(
            arguments: [
                "pattern": .string("**/*.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(result.output.contains("No files matched"))
    }

    @Test("hidden directories are skipped")
    func hiddenDirsSkipped() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("visible", to: "Foo.swift")
        _ = try dir.write("hidden", to: ".cache/Foo.swift")

        let result = try await GlobTool().execute(
            arguments: [
                "pattern": .string("**/Foo.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let lines = result.output.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(!result.output.contains(".cache"))
    }

    @Test("relative path is rejected")
    func relativePathRejected() async throws {
        let result = try await GlobTool().execute(
            arguments: [
                "pattern": .string("*.swift"),
                "path": .string("relative/dir")
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("absolute"))
    }

    @Test("`..` in pattern is rejected as path traversal")
    func dotDotInPatternRejected() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }

        let result = try await GlobTool().execute(
            arguments: [
                "pattern": .string("../**/*.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("path traversal"))
    }

    @Test("missing directory returns failure")
    func missingDirectoryFails() async throws {
        let result = try await GlobTool().execute(
            arguments: [
                "pattern": .string("**/*.swift"),
                "path": .string("/tmp/does-not-exist-\(UUID().uuidString)")
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("does not exist"))
    }

    @Test("brace alternation matches multiple extensions")
    func braceAlternationMatchesMultiExtensions() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "a.ts")
        _ = try dir.write("b", to: "b.tsx")
        _ = try dir.write("c", to: "c.js")

        let result = try await GlobTool().execute(
            arguments: [
                "pattern": .string("**/*.{ts,tsx}"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let lines = result.output.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(!result.output.contains("c.js"))
    }
}
