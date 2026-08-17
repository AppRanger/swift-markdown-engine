//
//  LiveTableGrid.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Everything the layout fragment needs to draw ONE row of a live table.
//
//  Stamped on the row's paragraph range as a single attribute, so the draw pass
//  is one `attribute(at:)` read rather than a scan — that read sits on the
//  per-keystroke height path.
//
//  A class, not a struct: one restyle builds a row's cells once and the same
//  reference is stamped across the paragraph, the way TableAnchor already works.
//
//  Coordinates are TABLE-LOCAL (origin at the table's top-left, y down) and the
//  drawer offsets them by the fragment's own draw point and the row's top.
//

import AppKit

final class LiveTableRowRender {

    let geometry: TableGeometry
    /// Row in `geometry`, or nil for the delimiter line, which has no measured
    /// row — it is collapsed to the hairline between header and body.
    let geometryRow: Int?
    /// One layout per cell of this row, already wrapped at its column width.
    let cells: [LiveTableCellLayout]
    /// The row's source line, terminator excluded. Containment is judged on this
    /// rather than on the cells' text spans: an offset can sit on a hidden pipe
    /// or in the padding between cells, which belongs to the row but to no
    /// cell — and answering "not in a live table" there let TextKit's own caret
    /// stand, contradicting the hit test that had just resolved the same point.
    let lineRange: NSRange
    /// The whole table's source range, so a click on a cell the row does not
    /// contain can be answered by editing the table rather than by guessing.
    let tableRange: NSRange
    let borderColor: NSColor
    let headerFill: NSColor

    init(
        geometry: TableGeometry,
        geometryRow: Int?,
        cells: [LiveTableCellLayout],
        lineRange: NSRange,
        tableRange: NSRange,
        borderColor: NSColor,
        headerFill: NSColor
    ) {
        self.geometry = geometry
        self.geometryRow = geometryRow
        self.cells = cells
        self.lineRange = lineRange
        self.tableRange = tableRange
        self.borderColor = borderColor
        self.headerFill = headerFill
    }

    var isDelimiter: Bool { geometryRow == nil }
    var isHeader: Bool { geometryRow == 0 }

    /// Height this row occupies, including its padding and the border below it.
    var rowHeight: CGFloat {
        guard let row = geometryRow else { return geometry.borderWidth }
        return geometry.rowPitch(row) ?? geometry.borderWidth
    }

    /// Extra space above the header's text.
    ///
    /// The bitmap draws row 0's text at `rowTop[0] + cellVPadding`, and
    /// `rowTop[0]` is the table's top border. The live header's paragraph starts
    /// at the table's top edge instead, so without this its text sits exactly
    /// one border higher — measured as a one-pixel shift against the bitmap.
    /// Body rows need no such term: the collapsed delimiter line contributes the
    /// same border between header and body.
    private var textTopInset: CGFloat {
        isHeader ? geometry.borderWidth : 0
    }

    /// Draw the row with `origin` at its top-left in view coordinates.
    ///
    /// Each row paints the rule BELOW it, so adjacent rows meet on exactly one
    /// line and no edge is filled twice. The header is the exception: the
    /// collapsed delimiter line is its rule, so the header paints none.
    func draw(at origin: CGPoint, pixelAlign: (CGFloat) -> CGFloat) {
        let width = geometry.totalSize.width
        let border = geometry.borderWidth

        if isDelimiter {
            // The collapsed line IS the header/body rule.
            borderColor.setFill()
            CGRect(x: origin.x, y: pixelAlign(origin.y), width: width, height: border).fill()
            return
        }
        guard geometryRow != nil else { return }
        let height = rowHeight

        if isHeader {
            // Fill below the top border, not under it, or the border reads
            // darker than the bitmap's.
            headerFill.setFill()
            CGRect(x: origin.x, y: origin.y + border,
                   width: width, height: max(0, height - border)).fill()
            borderColor.setFill()
            CGRect(x: origin.x, y: pixelAlign(origin.y), width: width, height: border).fill()
        }

        borderColor.setFill()
        // columnLeft's last entry IS the table's right edge, so this covers both
        // outer verticals and every separator between them.
        for edge in geometry.columnLeft {
            CGRect(x: pixelAlign(origin.x + edge - border), y: origin.y,
                   width: border, height: height).fill()
        }
        // One rule per row, once. The header's is the delimiter line.
        if !isHeader {
            CGRect(x: origin.x, y: pixelAlign(origin.y + height - border),
                   width: width, height: border).fill()
        }

        // Cells sit inside their padding, top-aligned like the bitmap draws them.
        for (column, cell) in cells.enumerated() where column < geometry.columnCount {
            guard let left = geometry.contentLeft(column) else { continue }
            cell.draw(
                at: CGPoint(x: origin.x + left,
                            y: origin.y + textTopInset + geometry.cellVPadding),
                alignment: geometry.alignments[column]
            )
        }
    }
}
