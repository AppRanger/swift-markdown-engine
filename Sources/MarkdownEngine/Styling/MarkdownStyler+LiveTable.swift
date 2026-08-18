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
    /// Why a table cannot use the live grid form; `nil` means it can.
    ///
    /// Named rather than a bare `false` because "it still shows raw pipes" has
    /// half a dozen possible causes, and guessing between them is expensive.
    enum LiveTableRefusal: Equatable {
        case malformed
        case widerThanContainer(tableWidth: CGFloat, available: CGFloat)
        case surplusCells(row: Int)
        case containsTab(row: Int)
        case inlineConstructInCell(row: Int, column: Int)
    }

    /// Every refusal here means "fall back to raw pipes", which is what the
    /// editor did for every table until now — a known, correct state.
    static func liveTableRefusal(
        layout: TableLayout,
        rows: [TableCells.Row],
        availableWidth: CGFloat,
        text: NSString,
        registry: ExtensionRegistry
    ) -> LiveTableRefusal? {
        let geometry = layout.geometry
        guard rows.count >= 2, geometry.columnCount > 0 else { return .malformed }

        // Wrapping rows are supported: the fragment draws each cell itself, so
        // a tall cell simply makes its row taller.
        for row in rows {
            // A surplus cell is truncated away by the parser, and the live form
            // cannot delete characters to match.
            if row.cells.count > geometry.columnCount { return .surplusCells(row: row.index) }
            // A tab would jump to a stop and desync the whole chain.
            for i in row.line.location..<NSMaxRange(row.line) where text.character(at: i) == 0x09 {
                return .containsTab(row: row.index)
            }
            // Emphasis, code and extension spans are styled in the live form now.
            // What still refuses is what the bitmap turns into an ATTACHMENT —
            // there is no character in the source to hang an image on.
            guard row.index != 1 else { continue }
            for (column, cell) in row.cells.enumerated() {
                let raw = text.substring(with: cell)
                guard !raw.isEmpty else { continue }
                if InlineParser.parse(raw, registry: registry).contains(where: \.rendersAsAttachment) {
                    return .inlineConstructInCell(row: row.index, column: column)
                }
            }
        }
        return nil
    }

    static func canGoLive(
        layout: TableLayout,
        rows: [TableCells.Row],
        availableWidth: CGFloat,
        text: NSString,
        registry: ExtensionRegistry
    ) -> Bool {
        liveTableRefusal(
            layout: layout, rows: rows, availableWidth: availableWidth,
            text: text, registry: registry
        ) == nil
    }

    /// A cell's own characters, styled the way the bitmap draws them.
    ///
    /// Built from the RAW source, not from `formattedCellString`: the formatted
    /// string strips markers, so its offsets no longer match the document and a
    /// click could not be resolved back to a character. Here every character
    /// survives and the markers are shrunk to `hiddenMarkerFontSize`, which is
    /// how the engine hides syntax everywhere else — so the visible width still
    /// matches what the picture measured, to within a fraction of a point.
    ///
    /// Constructs the bitmap renders RAW (links, wiki links) are left raw here
    /// too, or the two forms would disagree about a column's width.
    /// Styled cells, keyed by their source and the style inputs. Same reason as
    /// the line-break cache: the active table re-styles on every keystroke and
    /// only one cell has actually changed.
    private static let liveCellCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 4096
        return cache
    }()

    /// Everything a styled cell depends on, as one string. Shared with the
    /// line-break cache so both are keyed on the same identity.
    /// - Parameter caret: caret offset RELATIVE to the cell, or -1 when the
    ///   caret is elsewhere. Part of the key because it decides which markers are
    ///   revealed, and a revealed cell is a different string — and a different
    ///   width — from a hidden one.
    static func liveCellCacheKey(raw: String, header: Bool, caret: Int, ctx: StylingContext) -> String {
        "\(header ? 1 : 0)|\(caret)|\(ctx.baseFont.fontName)|\(ctx.baseFont.pointSize)|"
            + "\(ctx.configuration.extensionRegistry.fingerprint)|\(raw)"
    }

    /// Whether the caret is inside `range`, matching prose exactly
    /// (`MarkdownASTStyler.Ctx.isActive`): inside, or resting on the closing
    /// edge — but not across a line break, which a table cell cannot contain.
    private static func revealsMarkers(_ range: NSRange, caret: Int) -> Bool {
        if NSLocationInRange(caret, range) { return true }
        return range.length > 0 && caret == NSMaxRange(range)
    }

    static func liveCellString(
        raw: String,
        header: Bool,
        caret: Int,
        ctx: StylingContext
    ) -> NSAttributedString {
        let cacheKey = liveCellCacheKey(raw: raw, header: header, caret: caret, ctx: ctx) as NSString
        if let cached = liveCellCache.object(forKey: cacheKey) { return cached }

        let baseFont = ctx.baseFont
        let startFont = header
            ? (NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                      size: baseFont.pointSize) ?? baseFont)
            : baseFont
        let out = NSMutableAttributedString(string: raw, attributes: [
            .font: startFont,
            .foregroundColor: ctx.configuration.theme.bodyText,
        ])
        let hidden = ctx.latexMarkerFont
        let ns = raw as NSString

        /// Hide a marker so it occupies EXACTLY zero width.
        ///
        /// Shrinking to `hiddenMarkerFontSize` alone leaves ~0.05pt per marker,
        /// and that residue decides the line count whenever a cell's formatted
        /// width lands within it of the column edge — measured on 14% of
        /// emphasis-heavy cells across a width sweep. The row is measured from
        /// the stripped string, so a wider live string draws a line past its
        /// box. Kerning each character back by its own advance makes the two
        /// strings the same width by construction.
        func shrink(_ range: NSRange) {
            guard range.location >= 0, NSMaxRange(range) <= ns.length else { return }
            for i in range.location..<NSMaxRange(range) {
                let width = HeadingHelpers.textWidth(
                    ns.substring(with: NSRange(location: i, length: 1)), font: hidden
                )
                out.addAttributes([
                    .font: hidden,
                    .foregroundColor: NSColor.clear,
                    .kern: -width,
                ], range: NSRange(location: i, length: 1))
            }
        }
        func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, in range: NSRange) {
            guard range.location >= 0, NSMaxRange(range) <= ns.length else { return }
            out.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                guard let font = value as? NSFont, font.pointSize > 1 else { return }
                let traits = font.fontDescriptor.symbolicTraits.union(trait)
                if let composed = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits),
                                         size: font.pointSize) {
                    out.addAttribute(.font, value: composed, range: sub)
                }
            }
        }

        // An active construct reveals its whole subtree, so `**a `b` c**` opens
        // as one piece rather than leaving the inner backticks hidden.
        func walk(_ nodes: [InlineNode], forceReveal: Bool = false) {
            for node in nodes {
                switch node {
                case .text:
                    break
                case .emphasis(let kind, let range, let markers, let children):
                    let reveal = forceReveal || revealsMarkers(range, caret: caret)
                    walk(children, forceReveal: reveal)
                    // Trait first, then hide the markers — addTrait skips runs
                    // already shrunk, so the order keeps them hidden.
                    switch kind {
                    case .italic: addTrait(.italic, in: range)
                    case .bold: addTrait(.bold, in: range)
                    case .boldItalic:
                        addTrait(.bold, in: range)
                        addTrait(.italic, in: range)
                    }
                    if !reveal { markers.forEach(shrink) }
                case .code(let range, let content):
                    out.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular),
                        .backgroundColor: ctx.codeBackgroundColor,
                    ], range: content)
                    // The backticks on either side of the content.
                    if !(forceReveal || revealsMarkers(range, caret: caret)) {
                        shrink(NSRange(location: range.location, length: content.location - range.location))
                        shrink(NSRange(location: NSMaxRange(content),
                                       length: NSMaxRange(range) - NSMaxRange(content)))
                    }
                case .escape(let range, _, let marker):
                    if !(forceReveal || revealsMarkers(range, caret: caret)) { shrink(marker) }
                case .ext(let ext):
                    let extReveal = forceReveal || revealsMarkers(ext.range, caret: caret)
                    walk(ext.children, forceReveal: extReveal)
                    if !extReveal {
                        ext.markers.forEach(shrink)
                    }
                case .link, .wikiLink, .image, .imageEmbed, .inlineLatex:
                    // Rendered raw by the bitmap; leave raw so the widths agree.
                    break
                }
            }
        }
        walk(InlineParser.parse(raw, registry: ctx.configuration.extensionRegistry))
        // The break's own markup draws nothing — the layout turns it into a new
        // line instead. Kerned to zero like every other marker, so the live
        // string stays exactly as wide as the picture's.
        TableCells.hardBreaks(in: raw).forEach(shrink)
        liveCellCache.setObject(out, forKey: cacheKey)
        return out
    }

    /// Emit the live grid for one table.
    ///
    /// The row's own characters are hidden by SIZE (not by colour — a selection
    /// repaints colour-hidden runs opaque) and the visible grid is drawn by the
    /// layout fragment from the stamped `LiveTableRowRender`. The paragraph's
    /// forced line height is what reserves the room for it.
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

        // Same appearance resolution the bitmap uses, so both forms agree.
        let appearance = ctx.layoutBridge?.firstTextContainer?.textView?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        func mutedColor(alpha: CGFloat) -> NSColor {
            var resolved: NSColor = ctx.configuration.theme.mutedText
            appearance.performAsCurrentDrawingAppearance {
                resolved = ctx.configuration.theme.mutedText.usingColorSpace(.sRGB)
                    ?? ctx.configuration.theme.mutedText
            }
            return resolved.withAlphaComponent(alpha)
        }
        let borderColor = mutedColor(alpha: 0.5)
        let headerFill = mutedColor(alpha: 0.08)

        // Hide every character in the table; the fragment draws the real thing.
        attrs.append((tableRange, [
            .font: hiddenFont,
            .foregroundColor: NSColor.clear,
            // Cleared, not merely unset: attributes are applied over the
            // previous pass, so the picture's `.latexIsBlock` survives into the
            // live form. `applyBlockImageCaretPolicy` reads it and hides the
            // caret — inside a table you can type in, which is where the caret
            // once disappeared entirely.
            .latexIsBlock: false,
        ]))

        let lastRowIndex = rows.map(\.index).max() ?? 0

        for row in rows {
            let paragraph = ns.paragraphRange(for: NSRange(location: row.line.location, length: 0))
            let geometryRow = geometryRow(forLine: row.index)

            var cells: [LiveTableCellLayout] = []
            if let geometryRow, geometryRow < geometry.rowCount {
                for (column, cell) in row.cells.enumerated() where column < geometry.columnCount {
                    guard let left = geometry.contentLeft(column),
                          let right = geometry.contentRight(column) else { continue }
                    // Built from the SOURCE characters with markers shrunk, so a
                    // click resolves back to a real document offset.
                    let raw = ns.substring(with: cell)
                    let isHeader = geometryRow == 0
                    // -1 for every cell the caret is not in, so cells with the
                    // same text keep sharing one cache entry.
                    let caretLocal = revealsMarkers(cell, caret: ctx.caretLocation)
                        ? ctx.caretLocation - cell.location
                        : -1
                    let text = liveCellString(raw: raw, header: isHeader, caret: caretLocal, ctx: ctx)
                    cells.append(LiveTableCellLayout.make(
                        attributed: text,
                        sourceLocation: cell.location,
                        width: max(0, right - left),
                        lineHeight: layout.singleLineHeight,
                        caretRange: column < row.spans.count ? row.spans[column] : nil,
                        font: ctx.baseFont,
                        cacheKey: liveCellCacheKey(raw: raw, header: isHeader, caret: caretLocal, ctx: ctx)
                    ))
                }
            }

            let render = LiveTableRowRender(
                geometry: geometry,
                geometryRow: geometryRow,
                cells: cells,
                lineRange: row.line,
                tableRange: tableRange,
                rowHeight: LiveTableRowRender.height(
                    for: cells, geometryRow: geometryRow, geometry: geometry
                ),
                borderColor: borderColor,
                headerFill: headerFill
            )

            let style = NSMutableParagraphStyle()
            style.alignment = .left
            style.lineBreakMode = .byClipping
            // The base style installs tab stops; a pasted tab would otherwise
            // jump to one and desync the reserved height.
            style.tabStops = []
            style.defaultTabInterval = 0
            style.firstLineHeadIndent = 0
            style.headIndent = 0
            style.tailIndent = 0
            style.lineSpacing = 0
            style.paragraphSpacing = 0
            let height = render.rowHeight
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            if row.index == 0 {
                style.paragraphSpacingBefore = ctx.baseDefaultLineHeight * 0.5
            }
            if row.index == lastRowIndex {
                style.paragraphSpacing = ctx.baseDefaultLineHeight * 0.5
            }

            attrs.append((paragraph, [
                .paragraphStyle: style,
                .liveTableRow: render,
            ]))
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

private extension InlineNode {
    /// True when the bitmap renderer turns this node into an NSTextAttachment.
    /// The live form draws the source characters, and an attachment has none to
    /// draw — so a cell containing one keeps the raw-source fallback.
    var rendersAsAttachment: Bool {
        switch self {
        case .inlineLatex, .image, .imageEmbed:
            return true
        case .emphasis(_, _, _, let children):
            return children.contains(where: \.rendersAsAttachment)
        case .link(_, _, _, _, let children):
            return children.contains(where: \.rendersAsAttachment)
        case .ext(let ext):
            return ext.children.contains(where: \.rendersAsAttachment)
        case .text, .code, .wikiLink, .escape:
            return false
        }
    }
}
