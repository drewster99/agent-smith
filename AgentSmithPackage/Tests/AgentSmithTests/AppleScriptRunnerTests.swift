import Testing
import Foundation
@testable import AgentSmithKit

@Suite("AppleScriptRunner")
struct AppleScriptRunnerTests {

    @Test("string return → text + bare JSON string")
    func stringReturn() async {
        let r = await AppleScriptRunner.shared.run("return \"hello\"")
        #expect(r.success)
        #expect(r.resultText == "hello")
        #expect(r.descriptorType == "utxt")
        if case .string(let s) = r.result! { #expect(s == "hello") } else { Issue.record("expected .string") }
    }

    @Test("integer return → JSON int")
    func integerReturn() async {
        let r = await AppleScriptRunner.shared.run("return 42")
        #expect(r.success)
        if case .int(let n) = r.result! { #expect(n == 42) } else { Issue.record("expected .int") }
    }

    @Test("list with mixed types → JSON array, nested record merges usrf")
    func listWithRecord() async {
        let r = await AppleScriptRunner.shared.run("""
            return {1, \"two\", true, {|first|:\"Andrew\", |last|:\"R\"}}
            """)
        #expect(r.success)
        guard case .array(let items) = r.result! else { Issue.record("expected .array"); return }
        #expect(items.count == 4)
        if case .int(let n) = items[0] { #expect(n == 1) } else { Issue.record("[0] not int") }
        if case .string(let s) = items[1] { #expect(s == "two") } else { Issue.record("[1] not string") }
        if case .bool(let b) = items[2] { #expect(b) } else { Issue.record("[2] not bool") }
        guard case .object(let dict) = items[3] else { Issue.record("[3] not object"); return }
        #expect(dict["first"] == .string("Andrew"))
        #expect(dict["last"] == .string("R"))
    }

    @Test("date return → tagged $type:date")
    func dateReturn() async {
        let r = await AppleScriptRunner.shared.run("return current date")
        #expect(r.success)
        guard case .object(let dict) = r.result! else { Issue.record("expected .object"); return }
        #expect(dict["$type"] == .string("date"))
        if case .string(let iso) = dict["iso"]! {
            #expect(iso.contains("T") && iso.hasSuffix("Z"))
        }
    }

    @Test("missing value → JSON null")
    func missingValue() async {
        let r = await AppleScriptRunner.shared.run("return missing value")
        #expect(r.success)
        #expect(r.result == .null)
    }

    @Test("compile error → kind=.compile with line/column")
    func compileError() async {
        let r = await AppleScriptRunner.shared.run("this @@@ is not valid syntax")
        #expect(!r.success)
        let err = r.error
        #expect(err?.kind == .compile)
        #expect(err?.location != nil)
    }

    @Test("runtime error: divide by zero → kind=.runtime, number=-2701")
    func runtimeError() async {
        let r = await AppleScriptRunner.shared.run("1 / 0")
        #expect(!r.success)
        let err = r.error
        #expect(err?.kind == .runtime)
        #expect(err?.number == -2701)
    }

    @Test("missing target app → kind=.targetApp")
    func missingApp() async {
        let r = await AppleScriptRunner.shared.run("tell application \"NoSuchApp_xyz_123\" to activate")
        #expect(!r.success)
        let err = r.error
        #expect(err?.kind == .targetApp)
        #expect(err?.number == -1728)
    }
}
