//
//  TableGeometry.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  The numbers `renderTable` measures to draw a table's bitmap, kept instead of
//  dropped. Overlays that place chrome on a table (row/column affordances) and,
//  later, per-cell hit-testing read these rather than re-measuring — the same
//  one-source-of-truth reason TaskCheckboxGeometry exists.
//
//  Coordinates are the image's own: origin top-left, y down. That is the space
//  `NSImage(size:flipped: true)` hands its draw block, so these are literally
//  the numbers the renderer strokes with. NSTextView is flipped too, so a
//  consumer only adds the table's anchor origin.
//

import AppKit

/// The numbers the drawn grid is built from.
///
/// Shared because the live (editable) form has to place text on exactly the
/// same column edges the bitmap draws; re-deriving them in two places is how a
/// table starts twitching by a pixel whenever the caret enters it.
enum TableMetrics {
    static let cellHPadding: CGFloat = 12
    static let cellVPadding: CGFloat = 6
    static let borderWidth: CGFloat = 1
    static let minColumnContentWidth: CGFloat = 16
}

/// Measured layout of one rendered table, in image-local (y-down) points.
struct TableGeometry: Equatable {

    /// Keyed off `ParsedTable.alignments`, which is what `renderTable` sizes by.
    let columnCount: Int
    /// Header + body. **Row 0 is the header**; `ParsedTable.rows[i]` is row `i + 1`.
    let rowCount: Int

    let borderWidth: CGFloat
    let cellHPadding: CGFloat
    let cellVPadding: CGFloat

    /// `columnCount + 1` x-offsets; `columnLeft[c]` is column `c`'s cell-box left
    /// edge, the last entry the outer right border's.
    let columnLeft: [CGFloat]
    /// `rowCount + 1` y-offsets, same convention downward.
    let rowTop: [CGFloat]

    /// Per-column text width (cell box minus both `cellHPadding`).
    let columnWidths: [CGFloat]
    /// Per-row text height (cell box minus both `cellVPadding`).
    let rowContentHeights: [CGFloat]

    let alignments: [MarkdownStyler.TableAlignment]

    /// Equals the rendered `NSImage.size` exactly.
    let totalSize: CGSize
}

extension TableGeometry {

    var bounds: CGRect { CGRect(origin: .zero, size: totalSize) }

    /// x just past the outer right border — where a trailing affordance hangs.
    var rightEdge: CGFloat { totalSize.width }

    /// y just past the outer bottom border — where a bottom affordance hangs.
    var bottomEdge: CGFloat { totalSize.height }

    /// Cell box including its padding, excluding the borders around it.
    func cellRect(row: Int, column: Int) -> CGRect? {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return nil }
        let x = columnLeft[column]
        let y = rowTop[row]
        return CGRect(x: x, y: y,
                      width: columnLeft[column + 1] - x - borderWidth,
                      height: rowTop[row + 1] - y - borderWidth)
    }

    /// The rect the cell's text is drawn into — same arithmetic in the same order
    /// as `drawCell`, so anything placed here lands on the pixels the bitmap shows.
    func cellContentRect(row: Int, column: Int) -> CGRect? {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return nil }
        let cellLeft = columnLeft[column] + cellHPadding
        let cellRight = columnLeft[column + 1] - borderWidth - cellHPadding
        return CGRect(x: cellLeft,
                      y: rowTop[row] + cellVPadding,
                      width: cellRight - cellLeft,
                      height: rowContentHeights[row])
    }

    /// Column containing `x`; a point on a border belongs to the column left of it.
    /// Linear because column counts are single digits.
    func column(at x: CGFloat) -> Int? {
        guard columnCount > 0, x >= 0, x <= totalSize.width else { return nil }
        for c in 0..<columnCount where x < columnLeft[c + 1] { return c }
        return columnCount - 1
    }

    /// Row containing `y`; a point on a border belongs to the row above it.
    func row(at y: CGFloat) -> Int? {
        guard rowCount > 0, y >= 0, y <= totalSize.height else { return nil }
        for r in 0..<rowCount where y < rowTop[r + 1] { return r }
        return rowCount - 1
    }

    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        guard let r = row(at: point.y), let c = column(at: point.x) else { return nil }
        return (r, c)
    }

    /// Full vertical step from one row's top to the next — content, both
    /// paddings, and the border under it.
    func rowPitch(_ row: Int) -> CGFloat? {
        guard row >= 0, row < rowCount else { return nil }
        return rowTop[row + 1] - rowTop[row]
    }

    /// Left edge of a column's TEXT area.
    func contentLeft(_ column: Int) -> CGFloat? {
        guard column >= 0, column < columnCount else { return nil }
        return columnLeft[column] + cellHPadding
    }

    /// Right edge of a column's TEXT area.
    func contentRight(_ column: Int) -> CGFloat? {
        guard column >= 0, column < columnCount else { return nil }
        return columnLeft[column + 1] - borderWidth - cellHPadding
    }

    /// Where a cell's text actually starts, honouring the column's alignment.
    ///
    /// The live form needs this as an absolute x because one paragraph cannot
    /// carry three different alignments — it stays left-aligned and each cell is
    /// positioned outright.
    func alignedX(row: Int, column: Int, textWidth: CGFloat) -> CGFloat? {
        guard row >= 0, row < rowCount,
              let left = contentLeft(column), let right = contentRight(column) else { return nil }
        switch alignments[column] {
        case .left:   return left
        case .center: return left + max(0, (right - left) - textWidth) / 2
        case .right:  return right - textWidth
        }
    }
}

/// One rendered table: pixels plus the numbers that produced them.
///
/// A class because `NSCache` stores objects only, and keeping the pair in one box
/// stops the two halves from being evicted independently.
final class RenderedTable {
    let image: NSImage
    let geometry: TableGeometry

    init(image: NSImage, geometry: TableGeometry) {
        self.image = image
        self.geometry = geometry
    }
}

/// Everything a consumer needs about ONE occurrence of a rendered table,
/// stamped on its anchor character.
///
/// Split from ``RenderedTable`` because that one is cached by CONTENT — two
/// identical tables share it — while these three depend on where this table sits
/// and how the document is laid out. `gapBelow` in particular cannot live in the
/// cache: it comes from `baseDefaultLineHeight`, which prefers the layout
/// bridge's line height and is not part of the render key.
final class TableAnchor {
    let render: RenderedTable
    /// The table's source span — token range, so `NSMaxRange` is the append-row
    /// insertion point (the token ends before the last row's newline).
    let sourceRange: NSRange
    /// Content-derived, stable while the table's text is unchanged.
    let sourceID: Int
    /// Paragraph gap the styler leaves under the table.
    let gapBelow: CGFloat

    init(render: RenderedTable, sourceRange: NSRange, sourceID: Int, gapBelow: CGFloat) {
        self.render = render
        self.sourceRange = sourceRange
        self.sourceID = sourceID
        self.gapBelow = gapBelow
    }
}
