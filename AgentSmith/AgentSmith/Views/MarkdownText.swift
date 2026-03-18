import SwiftUI

/// Renders a string with basic markdown formatting.
///
/// Supports:
/// - Block headings: `# H1`, `## H2`, `### H3`
/// - Bullet lists: lines starting with `* ` or `- `
/// - Inline bold: `**text**`, italic: `*text*` or `_text_`, bold-italic: `***text***`
/// - Links: `[text](url)` and bare `https://` URLs
struct MarkdownText: View {
    let content: String
    let baseFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(contentLines) { item in
                renderLine(item.text)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Private

    private struct Line: Identifiable {
        let id: Int
        let text: String
    }

    private var contentLines: [Line] {
        content.components(separatedBy: "\n")
            .enumerated()
            .map { Line(id: $0.offset, text: $0.element) }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            Text(LocalizedStringKey(String(line.dropFirst(4))))
                .font(AppFonts.markdownH3)
        } else if line.hasPrefix("## ") {
            Text(LocalizedStringKey(String(line.dropFirst(3))))
                .font(AppFonts.markdownH2)
        } else if line.hasPrefix("# ") {
            Text(LocalizedStringKey(String(line.dropFirst(2))))
                .font(AppFonts.markdownH1)
        } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 4) {
                Text("•")
                    .font(baseFont)
                Text(LocalizedStringKey(linkifyBareURLs(String(line.dropFirst(2)))))
                    .font(baseFont)
            }
        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
            Color.clear.frame(height: 6)
        } else {
            Text(LocalizedStringKey(linkifyBareURLs(line)))
                .font(baseFont)
        }
    }

    /// Wraps bare `https?://` URLs (not already in markdown link syntax) with `[url](url)`,
    /// so that `Text(LocalizedStringKey(_:))` renders them as tappable links.
    private func linkifyBareURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![(\[])https?://[^\s)\]]+"#
        ) else { return text }

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
}
