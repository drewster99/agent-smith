import Testing
import Foundation
@testable import AgentSmithKit

@Suite("InstalledApplicationsScanner")
struct InstalledApplicationsTests {

    @Test("Scans /Applications and surfaces Xcode with parsed sdef")
    func scansXcode() async throws {
        let xcodeURL = URL(fileURLWithPath: "/Applications/Xcode.app")
        try #require(FileManager.default.fileExists(atPath: xcodeURL.path),
                     "Xcode.app must be installed at /Applications/Xcode.app for this test")

        let scanner = InstalledApplicationsScanner()
        let apps = await scanner.scan(roots: [URL(fileURLWithPath: "/Applications")])

        let xcode = try #require(apps.first { $0.url.lastPathComponent == "Xcode.app" })

        print("=== Xcode entry from InstalledApplicationsScanner ===")
        print("url:               \(xcode.url.path)")
        print("version:           \(xcode.version ?? "nil")")
        print("bundleIdentifier:  \(xcode.bundleIdentifier ?? "nil")")
        if let s = xcode.scripting {
            print("sdef url:                   \(s.url.path)")
            print("exposesNonStandardSuite:    \(s.exposesNonStandardSuite)")
            print("suiteNames:                 \(s.suiteNames.joined(separator: ", "))")
            print("renderedSchema chars/lines: \(s.renderedSchema.count) / \(s.renderedSchema.split(separator: "\n").count)")
            print("--- renderedSchema ---")
            print(s.renderedSchema)
            print("--- end renderedSchema ---")
        } else {
            print("scripting: nil")
        }

        #expect(xcode.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(xcode.scripting != nil)
        #expect(xcode.scripting?.exposesNonStandardSuite == true)
        #expect(xcode.scripting?.suiteNames.contains("Standard Suite") == true)
        #expect(xcode.scripting?.suiteNames.contains("Xcode Scheme Suite") == true)
    }
}
