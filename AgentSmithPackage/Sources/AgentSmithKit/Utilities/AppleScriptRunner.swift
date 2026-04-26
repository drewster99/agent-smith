import Foundation

// MARK: - Result types

/// Recursive JSON value used to represent AppleScript results structurally.
/// Round-trips through `JSONSerialization` and `Codable`.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Convert to a Foundation JSON object suitable for `JSONSerialization`.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.foundationValue)
        case .object(let v): return v.mapValues(\.foundationValue)
        }
    }
}

/// Result of `AppleScriptRunner.run(_:timeout:)`.
public struct AppleScriptResult: Sendable, Codable {
    public let success: Bool
    /// Recursively coerced descriptor as permissive-tagged JSON. `nil` on failure.
    public let result: JSONValue?
    /// Plain-text coercion of the descriptor (`coerce(toDescriptorType: typeUnicodeText)`),
    /// always populated on success even when `result` is structured. `nil` on failure.
    public let resultText: String?
    /// Four-character descriptor type code (e.g. `"utxt"`, `"list"`, `"reco"`). `nil` on failure.
    public let descriptorType: String?
    public let error: ScriptError?

    public init(success: Bool, result: JSONValue?, resultText: String?, descriptorType: String?, error: ScriptError?) {
        self.success = success
        self.result = result
        self.resultText = resultText
        self.descriptorType = descriptorType
        self.error = error
    }
}

/// Structured AppleScript error suitable for an LLM to read and respond to.
public struct ScriptError: Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// Failed to parse the script.
        case compile
        /// Compiled and started, but a runtime error occurred mid-execution.
        case runtime
        /// Runtime error specifically attributable to the target app of a `tell` block
        /// (missing app, app refused the command, etc.). Includes -1728 not-found.
        case targetApp
        /// Anything else (timeout, missing entitlement, etc.).
        case unknown
    }

    public let kind: Kind
    public let number: Int
    public let message: String
    /// Set when the error originated inside a `tell application "X"` block.
    public let appName: String?
    public let location: SourceLocation?

    public init(kind: Kind, number: Int, message: String, appName: String?, location: SourceLocation?) {
        self.kind = kind
        self.number = number
        self.message = message
        self.appName = appName
        self.location = location
    }
}

/// Line/column + short snippet of the source the error refers to.
public struct SourceLocation: Sendable, Codable {
    public let line: Int
    public let column: Int
    /// Source text the range covered, possibly with a few characters of context on either side.
    public let snippet: String

    public init(line: Int, column: Int, snippet: String) {
        self.line = line
        self.column = column
        self.snippet = snippet
    }
}

// MARK: - Runner

/// Executes AppleScript via `NSAppleScript` and returns a structured
/// `AppleScriptResult`. Compile and execute are split so we can tag errors
/// as `compile` vs `runtime`.
///
/// `NSAppleScript` is documented to be intended for main-thread use, and
/// background-thread invocation has been observed to fail with osa script
/// error -1751 in some sandboxes (notably the swiftpm test harness). All
/// execution is hopped to the main actor for that reason; the actor itself
/// just serializes calls into the main hop.
public actor AppleScriptRunner {
    public static let shared = AppleScriptRunner()

    public init() {}

    /// Compile and execute `source`. NSAppleScript blocks until the script
    /// returns; callers needing a hard wall-clock cap should wrap the script
    /// itself in `with timeout of N seconds ... end timeout` (NSAppleScript
    /// has no public cancel API).
    public func run(_ source: String) async -> AppleScriptResult {
        await Self.runOnMain(source: source)
    }

    // MARK: - Implementation

    @MainActor
    private static func runOnMain(source: String) -> AppleScriptResult {
        runSync(source: source)
    }

    private static func runSync(source: String) -> AppleScriptResult {
        guard let script = NSAppleScript(source: source) else {
            return AppleScriptResult(
                success: false,
                result: nil,
                resultText: nil,
                descriptorType: nil,
                error: ScriptError(kind: .unknown, number: 0, message: "NSAppleScript could not be initialized from source.", appName: nil, location: nil)
            )
        }

        // Compile first so we can distinguish compile errors from runtime errors.
        var compileError: NSDictionary?
        if !script.compileAndReturnError(&compileError) {
            return failureResult(from: compileError, source: source, defaultKind: .compile)
        }

        var execError: NSDictionary?
        let descriptor = script.executeAndReturnError(&execError)
        if let execError {
            return failureResult(from: execError, source: source, defaultKind: .runtime)
        }

        let coerced = AppleScriptCoercer.coerce(descriptor)
        let text = descriptor.coerce(toDescriptorType: typeUnicodeText)?.stringValue ?? ""
        return AppleScriptResult(
            success: true,
            result: coerced,
            resultText: text,
            descriptorType: fourCharCode(descriptor.descriptorType),
            error: nil
        )
    }

    private static func failureResult(from errorDict: NSDictionary?, source: String, defaultKind: ScriptError.Kind) -> AppleScriptResult {
        let number = (errorDict?[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (errorDict?[NSAppleScript.errorMessage] as? String)
            ?? (errorDict?[NSAppleScript.errorBriefMessage] as? String)
            ?? "Unknown AppleScript error."
        let appName = errorDict?[NSAppleScript.errorAppName] as? String
        let location: SourceLocation? = {
            guard let rangeValue = errorDict?[NSAppleScript.errorRange] as? NSValue else { return nil }
            let range = rangeValue.rangeValue
            return makeSourceLocation(source: source, range: range)
        }()
        let kind = classifyError(number: number, defaultKind: defaultKind, appName: appName)
        return AppleScriptResult(
            success: false,
            result: nil,
            resultText: nil,
            descriptorType: nil,
            error: ScriptError(kind: kind, number: number, message: message, appName: appName, location: location)
        )
    }

    private static func classifyError(number: Int, defaultKind: ScriptError.Kind, appName: String?) -> ScriptError.Kind {
        // The compile-vs-runtime distinction comes from which NSAppleScript call failed
        // (compileAndReturnError vs executeAndReturnError) — see callers' `defaultKind`.
        // Error-number ranges are unreliable: e.g. -2701 ("Can't divide by zero") is a
        // runtime semantic error but sits in the same -27xx family as compile errors.
        // Only override the default for unambiguous targetApp signals.
        if number == -1728 { return .targetApp }
        if appName != nil && defaultKind == .runtime { return .targetApp }
        return defaultKind
    }

    private static func makeSourceLocation(source: String, range: NSRange) -> SourceLocation? {
        guard range.location != NSNotFound, range.location <= source.utf16.count else { return nil }
        let utf16 = source.utf16
        guard let start = String.Index(utf16.index(utf16.startIndex, offsetBy: range.location), within: source) else { return nil }

        var line = 1
        var column = 1
        for ch in source[..<start] {
            if ch == "\n" { line += 1; column = 1 }
            else { column += 1 }
        }

        let snippetLowerOffset = max(0, range.location - 20)
        let snippetUpperOffset = min(source.utf16.count, range.location + range.length + 20)
        let snippetLower = String.Index(utf16.index(utf16.startIndex, offsetBy: snippetLowerOffset), within: source) ?? source.startIndex
        let snippetUpper = String.Index(utf16.index(utf16.startIndex, offsetBy: snippetUpperOffset), within: source) ?? source.endIndex
        let snippet = String(source[snippetLower..<snippetUpper]).replacingOccurrences(of: "\n", with: "⏎")

        return SourceLocation(line: line, column: column, snippet: snippet)
    }
}

// MARK: - Coercion

enum AppleScriptCoercer {

    /// Recursively coerce an AppleEvent descriptor to permissive-tagged JSON.
    /// Primitives become bare JSON values; types with no JSON equivalent (date,
    /// alias, object specifier, type-name, enumerator) become tagged objects of
    /// the form `{"$type": "...", ...}`.
    static func coerce(_ d: NSAppleEventDescriptor) -> JSONValue {
        switch d.descriptorType {
        case typeUnicodeText, typeUTF8Text, typeUTF16ExternalRepresentation:
            return .string(d.stringValue ?? "")

        case typeBoolean, typeTrue, typeFalse:
            return .bool(d.booleanValue)

        case typeSInt16, typeSInt32, typeUInt16, typeUInt32:
            return .int(Int(d.int32Value))

        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint, type128BitFloatingPoint:
            return .double(d.doubleValue)

        case typeLongDateTime:
            let iso = ISO8601DateFormatter()
            let stamp = d.dateValue.map { iso.string(from: $0) } ?? ""
            return .object(["$type": .string("date"), "iso": .string(stamp)])

        case typeAlias, typeFileURL, typeFSRef:
            if let url = d.fileURLValue {
                return .object([
                    "$type": .string("alias"),
                    "path": .string(url.path),
                    "url": .string(url.absoluteString)
                ])
            }
            return taggedFallback(d, type: "alias")

        case typeObjectSpecifier:
            let text = d.coerce(toDescriptorType: typeUnicodeText)?.stringValue ?? ""
            return .object([
                "$type": .string("objectSpecifier"),
                "text": .string(text)
            ])

        case typeType:
            // `missing value` and class names both arrive as typeType. Both map cleanly
            // to a four-char code; we tag as typeName so the LLM can tell.
            let code = fourCharCode(d.typeCodeValue)
            if code == "msng" { return .null }
            return .object([
                "$type": .string("typeName"),
                "code": .string(code)
            ])

        case typeEnumerated:
            let code = fourCharCode(d.enumCodeValue)
            return .object([
                "$type": .string("enum"),
                "code": .string(code)
            ])

        case typeNull:
            return .null

        case typeAEList:
            var items: [JSONValue] = []
            if d.numberOfItems > 0 {
                for i in 1...d.numberOfItems {
                    if let item = d.atIndex(i) {
                        items.append(coerce(item))
                    }
                }
            }
            return .array(items)

        case typeAERecord:
            return coerceRecord(d)

        default:
            return taggedFallback(d, type: fourCharCode(d.descriptorType))
        }
    }

    /// AppleScript records have two kinds of keys:
    /// - "registered" four-char codes (e.g. `pnam`, `pidx`) reachable via
    ///   `keywordForDescriptor(at:)` and `forKeyword(_:)`.
    /// - User-defined string keys, packed into a single child descriptor under
    ///   the `usrf` keyword as a flat alternating `[k1, v1, k2, v2, ...]` list.
    /// We merge both into one JSON object so LLMs see the natural shape.
    private static func coerceRecord(_ d: NSAppleEventDescriptor) -> JSONValue {
        var dict: [String: JSONValue] = [:]
        if d.numberOfItems > 0 {
            for i in 1...d.numberOfItems {
                let key = d.keywordForDescriptor(at: i)
                guard let value = d.forKeyword(key) else { continue }
                let keyString = fourCharCode(key)
                if keyString == "usrf", case .array(let pairs) = coerce(value) {
                    var idx = 0
                    while idx + 1 < pairs.count {
                        if case .string(let k) = pairs[idx] {
                            dict[k] = pairs[idx + 1]
                        }
                        idx += 2
                    }
                } else {
                    dict[keyString] = coerce(value)
                }
            }
        }
        return .object(dict)
    }

    /// Last-ditch coercion: ask AppleScript itself to produce text. Always
    /// tagged so the LLM knows it's seeing a fallback.
    private static func taggedFallback(_ d: NSAppleEventDescriptor, type: String) -> JSONValue {
        let text = d.coerce(toDescriptorType: typeUnicodeText)?.stringValue
        var obj: [String: JSONValue] = ["$type": .string(type)]
        if let text { obj["text"] = .string(text) }
        return .object(obj)
    }
}

/// Convert a four-char `OSType` to its ASCII representation, falling back to
/// hex when any byte is non-printable.
func fourCharCode(_ code: DescType) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    if bytes.allSatisfy({ (32...126).contains($0) }) {
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", code)
    }
    return String(format: "0x%08x", code)
}
