import Foundation

/// Wraps plain text with markdown link syntax (`[text](url)`) for URLs, emails, and
/// absolute file paths that exist on disk. Designed to feed `AttributedString(markdown:)`
/// so the resulting `Text` carries a real `.link` attribute (clickable, right-clickable,
/// surviving `.textSelection(.enabled)`).
///
/// All helpers are pure-Foundation and side-effect-free apart from `FileManager.fileExists`
/// for path-validity checks.
public enum PathLinkifier {

    /// Compiled once and reused across all calls.
    /// `try?` — pattern is a compile-time literal; init only fails for malformed
    /// patterns, which would be caught at first run during development.
    private static let bareURLRegex = try? NSRegularExpression(
        pattern: #"(?<![(\[])https?://[^\s)\]*]+"#
    )

    /// Matches plain email addresses not already inside markdown link syntax. Conservative:
    /// requires standard local@domain.tld shape with at least one TLD-like suffix. Negative
    /// lookbehind on `[`, `(`, `:` skips emails already wrapped as a markdown link or used
    /// as a `mailto:` URL component.
    /// `try?` — same rationale as `bareURLRegex`: literal pattern, compile-time correct.
    private static let emailRegex = try? NSRegularExpression(
        pattern: #"(?<![\[(:])[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    )

    /// Matches absolute POSIX paths starting with `/` or `~/`.
    /// Negative lookbehind excludes: existing markdown link syntax (`[` / `(`),
    /// URL scheme tails (`:` / `/`), and word-adjacent slashes like `a/b` which
    /// aren't filesystem paths.
    /// `try?` — same rationale as `bareURLRegex`: literal pattern, compile-time correct.
    private static let pathRegex = try? NSRegularExpression(
        pattern: #"(?<![\w/:\[(])(?:~/|/)[A-Za-z0-9._/~\-]+"#
    )

    /// True when `text` (after trimming whitespace) is a single token that the
    /// linkifier would turn into a real link: an existing absolute path, an
    /// http(s)/file/mailto URL, or a bare email. Used by callers that need to decide
    /// up front whether a backtick-wrapped span should be styled as inline code or
    /// instead routed through `linkify` to become a clickable link.
    public static func isStandaloneLinkable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }) else { return false }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("file://") || trimmed.hasPrefix("mailto:") {
            return URL(string: trimmed) != nil
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded)
        }

        if let regex = emailRegex {
            let nsRange = NSRange(location: 0, length: (trimmed as NSString).length)
            if let match = regex.firstMatch(in: trimmed, range: nsRange),
               match.range == nsRange {
                return true
            }
        }
        return false
    }

    /// Runs all inline linkification passes in the order that avoids collisions:
    /// path wrapping first (emits `file://` markdown links), then bare URL wrapping,
    /// then email wrapping (emits `mailto:` markdown links).
    public static func linkify(_ text: String) -> String {
        linkifyEmails(linkifyBareURLs(linkifyPaths(text)))
    }

    /// Wraps absolute file paths that exist on disk with `[path](file:///...)` markdown.
    /// Non-existent paths are left untouched. Trailing sentence punctuation (`.,;:)]`) is
    /// preserved outside the link so "see /foo/bar." doesn't try to open `/foo/bar.`.
    /// `~/`-prefixed paths are expanded against the user's home directory for the existence
    /// check and the link URL, but the link **text** keeps the original `~/...` form so
    /// users see what they typed.
    public static func linkifyPaths(_ text: String) -> String {
        guard let regex = pathRegex else { return text }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = text.startIndex
        let fm = FileManager.default

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[lastEnd..<range.lowerBound]
            lastEnd = range.upperBound

            var candidate = String(text[range])
            var trailing = ""
            while let last = candidate.last, ".,;:)]".contains(last) {
                trailing = String(last) + trailing
                candidate.removeLast()
            }

            guard !candidate.isEmpty else {
                result += String(text[range])
                continue
            }

            let expanded = (candidate as NSString).expandingTildeInPath
            guard fm.fileExists(atPath: expanded) else {
                result += String(text[range])
                continue
            }

            // `URL(fileURLWithPath:)` handles percent-encoding of spaces, unicode, etc.
            let urlString = URL(fileURLWithPath: expanded).absoluteString
            result += "[\(candidate)](\(urlString))\(trailing)"
        }
        result += text[lastEnd...]
        return result
    }

    /// Wraps bare `https?://` URLs (not already in markdown link syntax) with `[url](url)`
    /// so they parse as real markdown links via `AttributedString(markdown:)`.
    public static func linkifyBareURLs(_ text: String) -> String {
        guard let regex = bareURLRegex else { return text }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, range: fullRange)

        var result = ""
        var lastEnd = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[lastEnd..<range.lowerBound]
            let url = String(text[range])
            result += "[\(url)](\(url))"
            lastEnd = range.upperBound
        }
        result += text[lastEnd...]
        return result
    }

    /// Wraps plain email addresses with `[email](mailto:email)` so they render as clickable
    /// `mailto:` links via the AttributedString markdown parser. Unlike `LocalizedStringKey`,
    /// the AttributedString markdown parser does NOT auto-detect emails — explicit wrapping
    /// is required to make them clickable.
    public static func linkifyEmails(_ text: String) -> String {
        guard let regex = emailRegex else { return text }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[lastEnd..<range.lowerBound]
            let email = String(text[range])
            result += "[\(email)](mailto:\(email))"
            lastEnd = range.upperBound
        }
        result += text[lastEnd...]
        return result
    }
}
