import SwiftUI

/// Renders a string with markdown formatting.
///
/// Supports:
/// - Block headings: `# H1`, `## H2`, `### H3`
/// - Bullet lists: lines starting with `* ` or `- `
/// - Pipe-delimited tables with a separator row
/// - Inline bold: `**text**`, italic: `*text*` or `_text_`, bold-italic: `***text***`
/// - Links: `[text](url)` and bare `https://` URLs
struct MarkdownText: View {
    let content: String
    let baseFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(contentBlocks) { block in
                renderBlock(block)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Block model

    private enum ContentBlock: Identifiable {
        case line(id: Int, text: String)
        /// Rows × columns; the first row is the header.
        case table(id: Int, rows: [[String]])

        var id: Int {
            switch self {
            case .line(let id, _):  return id
            case .table(let id, _): return id
            }
        }
    }

    private var contentBlocks: [ContentBlock] {
        let lines = content.components(separatedBy: "\n")
        var result: [ContentBlock] = []
        var i = 0
        var nextID = 0

        while i < lines.count {
            // Table detected when current line looks like a data row and the next is a separator.
            if i + 1 < lines.count,
               isTableDataRow(lines[i]),
               isTableSeparatorRow(lines[i + 1]) {
                var tableLines: [String] = []
                while i < lines.count,
                      isTableDataRow(lines[i]) || isTableSeparatorRow(lines[i]) {
                    tableLines.append(lines[i])
                    i += 1
                }
                let rows = tableLines
                    .filter { !isTableSeparatorRow($0) }
                    .map { parseTableRow($0) }
                if !rows.isEmpty {
                    result.append(.table(id: nextID, rows: rows))
                    nextID += 1
                }
            } else {
                result.append(.line(id: nextID, text: lines[i]))
                nextID += 1
                i += 1
            }
        }
        return result
    }

    // MARK: - Table parsing

    /// A data row has at least one `|`.
    private func isTableDataRow(_ line: String) -> Bool {
        line.contains("|")
    }

    /// A separator row contains only `-`, `:`, `|`, space, and tab.
    private func isTableSeparatorRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        return line.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " || $0 == "\t" }
    }

    private func parseTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty  == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Rendering

    @ViewBuilder
    private func renderBlock(_ block: ContentBlock) -> some View {
        switch block {
        case .line(_, let text):
            renderLine(text)
        case .table(_, let rows):
            if let columnCount = rows.map(\.count).max(), columnCount > 0 {
                tableView(rows: rows, columnCount: columnCount)
            }
        }
    }

    /// Renders a pipe-delimited table. Columns share width equally; the first row is bold.
    private func tableView(rows: [[String]], columnCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { colIdx in
                        let cell = linkifyBareURLs(colIdx < row.count ? row[colIdx] : "")
                        Group {
                            if rowIdx == 0 {
                                Text(LocalizedStringKey(cell))
                                    .font(baseFont)
                                    .fontWeight(.semibold)
                            } else {
                                Text(LocalizedStringKey(cell))
                                    .font(baseFont)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rowIdx == 0 ? Color.secondary.opacity(0.12) : Color.clear)
                    }
                }
                Divider()
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.vertical, 4)
    }

    /// Parses a line's leading whitespace and bullet/number prefix, returning
    /// the nesting depth (in spaces), whether it's a list item, and the content text.
    private struct LineParse {
        let indent: Int         // leading whitespace count
        let isList: Bool        // true for bullet or numbered list items
        let isNumbered: Bool    // true for "1." style lists
        let numberPrefix: String // e.g. "1." — preserved for display
        let content: String     // text after the prefix
    }

    private func parseLine(_ line: String) -> LineParse {
        let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = line.count - stripped.count

        // Bullet markers: "* ", "- "
        if stripped.hasPrefix("* ") || stripped.hasPrefix("- ") {
            return LineParse(indent: indent, isList: true, isNumbered: false, numberPrefix: "", content: String(stripped.dropFirst(2)))
        }
        // Unicode bullet: "• " or "•" (some LLMs omit the trailing space)
        if stripped.hasPrefix("•") {
            let afterBullet = stripped.dropFirst(1).drop(while: { $0 == " " })
            return LineParse(indent: indent, isList: true, isNumbered: false, numberPrefix: "", content: String(afterBullet))
        }

        // Numbered list: "1. ", "2) ", etc. — preserve the prefix for display
        if let match = stripped.prefixMatch(of: /\d+[.)]\s+/) {
            let prefix = String(stripped[match.range]).trimmingCharacters(in: .whitespaces)
            return LineParse(indent: indent, isList: true, isNumbered: true, numberPrefix: prefix, content: String(stripped[match.range.upperBound...]))
        }

        return LineParse(indent: indent, isList: false, isNumbered: false, numberPrefix: "", content: String(stripped))
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("### ") {
            Text(LocalizedStringKey(linkifyBareURLs(String(trimmed.dropFirst(4)))))
                .font(AppFonts.markdownH3)
        } else if trimmed.hasPrefix("## ") {
            Text(LocalizedStringKey(linkifyBareURLs(String(trimmed.dropFirst(3)))))
                .font(AppFonts.markdownH2)
        } else if trimmed.hasPrefix("# ") {
            Text(LocalizedStringKey(linkifyBareURLs(String(trimmed.dropFirst(2)))))
                .font(AppFonts.markdownH1)
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 6)
        } else {
            let parsed = parseLine(line)
            if parsed.isList {
                // Indent based on leading whitespace: 12pt base + 12pt per 2-space level
                let depthPadding = CGFloat(max(0, parsed.indent / 2)) * 12
                let marker = parsed.isNumbered ? parsed.numberPrefix : "•"
                HStack(alignment: .top, spacing: 4) {
                    Text(marker)
                        .font(baseFont)
                    Text(LocalizedStringKey(linkifyBareURLs(parsed.content)))
                        .font(parsed.isNumbered ? baseFont.bold() : baseFont)
                }
                .padding(.leading, depthPadding)
            } else if parsed.indent > 0 {
                // Indented non-list text — preserve the indent
                let depthPadding = CGFloat(max(0, parsed.indent / 2)) * 12
                Text(LocalizedStringKey(linkifyBareURLs(parsed.content)))
                    .font(baseFont)
                    .padding(.leading, depthPadding)
            } else {
                Text(LocalizedStringKey(linkifyBareURLs(line)))
                    .font(baseFont)
            }
        }
    }

    /// Wraps bare `https?://` URLs (not already in markdown link syntax) with `[url](url)`,
    /// so that `Text(LocalizedStringKey(_:))` renders them as tappable links.
    private func linkifyBareURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![(\[])https?://[^\s)\]*]+"#
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
