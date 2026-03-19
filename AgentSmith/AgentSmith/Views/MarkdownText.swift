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

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            Text(LocalizedStringKey(linkifyBareURLs(String(line.dropFirst(4)))))
                .font(AppFonts.markdownH3)
        } else if line.hasPrefix("## ") {
            Text(LocalizedStringKey(linkifyBareURLs(String(line.dropFirst(3)))))
                .font(AppFonts.markdownH2)
        } else if line.hasPrefix("# ") {
            Text(LocalizedStringKey(linkifyBareURLs(String(line.dropFirst(2)))))
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
