import SwiftUI

/// One row of a pipe-delimited markdown table. The parent renders each cell as a styled
/// `Text` (so this view doesn't need access to MarkdownText's inline parser) and we lay
/// them out in an HStack with a trailing divider — collapsed into a single view per
/// ForEach iteration in `MarkdownText.tableView`.
struct MarkdownTableRow: View {
    let renderedCells: [Text]
    let isHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(renderedCells.enumerated()), id: \.offset) { _, cell in
                    cell
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isHeader ? AppColors.tableHeaderBackground : Color.clear)
                }
            }
            Divider()
        }
    }
}
