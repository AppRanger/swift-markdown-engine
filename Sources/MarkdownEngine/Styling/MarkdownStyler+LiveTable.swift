//
//  MarkdownStyler+LiveTable.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  The table the caret is inside, laid out as REAL TEXT that still looks like
//  the rendered grid — so typing in a cell is just typing (Obsidian's
//  behaviour), instead of dumping the raw `|` source.
//
//  How it works: the pipes and the padding around them stay in storage — the
//  engine's "markers shrink, they don't disappear" invariant — but are drawn at
//  `hiddenMarkerFontSize` in clear, and each one carries a `.kern` that pushes
//  the pen to the next column's measured x. So a row is one clipped line whose
//  glyphs land exactly where the bitmap draws them.
//
//  It is a KERN chain and not `NSTextTab` on purpose: paragraph tab stops act
//  only on U+0009, and a GFM row contains none. Inserting one would change the
//  document.
//
//  Only tables that fit one line per row go live — see `canGoLive`. A kern chain
//  cannot survive a line wrap (the pen restarts at the head indent, so every
//  kern after the break is off by the width of the first line), so a wrapping
//  table keeps the old raw-source form rather than rendering wrong.
//

import AppKit

extension MarkdownStyler {

    /// Whether this table can be shown in the live grid form.
    ///
    /// Every refusal here means "fall back to raw pipes", which is what the
    /// editor did for every table until now — a known, correct state.
    static func canGoLive(
        layout: TableLayout,
        rows: [TableCells.Row],
        availableWidth: CGFloat,
        text: NSString,
        registry: ExtensionRegistry
    ) -> Bool {
        let geometry = layout.geometry
        guard rows.count >= 2, geometry.columnCount > 0 else { return false }

        // A wrapped row would break the kern chain: the pen restarts at the head
        // indent on the continuation line, so every kern after the break is off
        // by the width of the first line.
        if layout.didShrinkColumns { return false }
        // A table wider than the column is hosted in a scrolling image view;
        // there is no live analogue for that yet.
        if geometry.totalSize.width > availableWidth + 0.5 { return false }

        for row in rows {
            // A surplus cell is truncated away by the parser, and the live form
            // cannot delete characters to match.
            if row.cells.count > geometry.columnCount { return false }
            // A tab would jump to a stop and desync the whole chain.
            for i in row.line.location..<NSMaxRange(row.line) where text.character(at: i) == 0x09 {
                return false
            }
            // Step 1 accepts plain text only: anything the bitmap renders as an
            // attachment or a styled span needs the cell-level inline styling
            // that comes with the next slice.
            guard row.index != 1 else { continue }
            for cell in row.cells {
                let raw = text.substring(with: cell)
                guard raw.isEmpty || InlineParser.parse(raw, registry: registry).allSatisfy({
                    if case .text = $0 { return true }
                    return false
                }) else { return false }
            }
        }
        return true
    }

    /// Emit the live grid for one table.
    static func styleLiveTable(
        tableRange: NSRange,
        layout: TableLayout,
        rows: [TableCells.Row],
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        let geometry = layout.geometry
        let ns = ctx.nsText
        let hiddenFont = ctx.latexMarkerFont
        let baseFont = ctx.baseFont
        let boldFont = NSFont(
            descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
            size: baseFont.pointSize
        ) ?? baseFont

        // Cell text reads as body text; the structural runs below overwrite
        // themselves on top of this.
        attrs.append((tableRange, [
            .foregroundColor: ctx.configuration.theme.bodyText,
            .font: baseFont,
        ]))

        /// Hide `from..<to` and make the run advance exactly `advance` points.
        ///
        /// Per character, because `.kern` is per character: a single attribute
        /// over n characters adds n × kern, not kern. Everything but the last
        /// character cancels its own width; the last one carries the whole step.
        func hide(from: Int, to: Int, advance: CGFloat) {
            guard to > from else { return }
            for i in from..<to {
                let width = HeadingHelpers.textWidth(
                    ns.substring(with: NSRange(location: i, length: 1)), font: hiddenFont
                )
                let kern = (i == to - 1) ? advance - width : -width
                attrs.append((NSRange(location: i, length: 1), [
                    .font: hiddenFont,
                    .foregroundColor: NSColor.clear,
                    .kern: kern,
                ]))
            }
        }

        for row in rows {
            let paragraph = ns.paragraphRange(for: NSRange(location: row.line.location, length: 0))

            // The delimiter row carries no content in the picture; collapse it to
            // the hairline that separates header from body.
            if row.index == 1 {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byClipping
                style.tabStops = []
                style.defaultTabInterval = 0
                style.minimumLineHeight = TableMetrics.borderWidth
                style.maximumLineHeight = TableMetrics.borderWidth
                attrs.append((paragraph, [.paragraphStyle: style]))
                hide(from: row.line.location, to: NSMaxRange(row.line), advance: 0)
                continue
            }

            guard let geometryRow = geometryRow(forLine: row.index) ,
                  geometryRow < geometry.rowCount else { continue }

            let style = NSMutableParagraphStyle()
            style.alignment = .left          // each cell is positioned outright
            style.lineBreakMode = .byClipping
            // The base style installs tab stops; left in place a pasted tab would
            // jump to one and desync every kern after it.
            style.tabStops = []
            style.defaultTabInterval = 0
            style.firstLineHeadIndent = 0
            style.headIndent = 0
            style.tailIndent = 0
            style.lineSpacing = 0
            // Slack in a forced line box goes ABOVE the text, so this puts the
            // baseline at cellVPadding + ascent — where `drawCell` puts it.
            let lineHeight = TableMetrics.cellVPadding + geometry.rowContentHeights[geometryRow]
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            style.paragraphSpacing = TableMetrics.cellVPadding + TableMetrics.borderWidth
            if row.index == 0 {
                style.paragraphSpacingBefore = ctx.baseDefaultLineHeight * 0.5 + TableMetrics.borderWidth
            }
            attrs.append((paragraph, [.paragraphStyle: style]))

            let isHeader = geometryRow == 0
            var pen: CGFloat = 0
            var previousEnd = row.line.location

            for (column, cell) in row.cells.enumerated() where column < geometry.columnCount {
                let raw = ns.substring(with: cell)
                let font = isHeader ? boldFont : baseFont
                let width = HeadingHelpers.textWidth(raw, font: font)
                guard let target = geometry.alignedX(row: geometryRow, column: column, textWidth: width)
                else { continue }

                hide(from: previousEnd, to: cell.location, advance: target - pen)
                if isHeader, cell.length > 0 {
                    attrs.append((cell, [.font: boldFont]))
                }
                pen = target + width
                previousEnd = NSMaxRange(cell)
            }

            // Land the line exactly on the table's right edge, so the drawn
            // border and the text box agree.
            hide(from: previousEnd, to: NSMaxRange(row.line), advance: geometry.totalSize.width - pen)
        }
    }

    /// Source line index → geometry row. Line 1 is the delimiter, which the
    /// measured grid does not have a row for.
    private static func geometryRow(forLine line: Int) -> Int? {
        switch line {
        case 0: return 0
        case 1: return nil
        default: return line - 1
        }
    }
}
