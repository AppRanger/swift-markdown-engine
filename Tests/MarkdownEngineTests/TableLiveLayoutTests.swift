//
//  TableLiveLayoutTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  The live (typeable) table form. TextKit 2 cannot lay out columns whose cells
//  wrap, so the row is one hidden line whose paragraph reserves the grid's
//  height, and the layout fragment draws the cells itself. These pin the two
//  halves of that contract: the reserved height matches the measured grid, and
//  each row carries the cell layouts the fragment will draw.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Live table layout")
struct TableLiveLayoutTests {
    private let availableWidth: CGFloat = 650

    private func context(for text: String) -> MarkdownStyler.StylingContext {
        let font = NSFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: MarkdownTokenizer.parseTokensViaAST(in: text),
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: NSFont.systemFont(ofSize: 0.1),
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )
        ctx.scopeBounds = nil
        return ctx
    }

    private struct Styled {
        let attrs: [StyledRange]
        let layout: MarkdownStyler.TableLayout
        let rows: [TableCells.Row]
        let text: NSString
    }

    private func styleLive(_ text: String, width: CGFloat? = nil) throws -> Styled {
        _ = NSApplication.shared
        let available = width ?? availableWidth
        let ctx = context(for: text)
        let token = try #require(ctx.tokens.first { $0.kind == .table })
        let parsed = try #require(MarkdownStyler.parseTableSource(ctx.nsText.substring(with: token.range)))
        let layout = MarkdownStyler.measureTable(
            parsed, baseFont: ctx.baseFont, theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
            availableWidth: available, extensions: ctx.configuration.extensions
        )
        let rows = TableCells.rows(in: ctx.nsText, tableRange: token.range)
        var attrs: [StyledRange] = []
        MarkdownStyler.styleLiveTable(
            tableRange: token.range, layout: layout, rows: rows, ctx: ctx, attrs: &attrs
        )
        return Styled(attrs: attrs, layout: layout, rows: rows, text: ctx.nsText)
    }

    /// Row renders in source order.
    private func renders(_ styled: Styled) -> [LiveTableRowRender] {
        styled.attrs.compactMap { $0.attributes[.liveTableRow] as? LiveTableRowRender }
    }

    private let wrappingTable = """
    | Rechtsform | Gründungskosten | Laufende Kosten |
    |---|---|---|
    | Einzelunternehmen Kleingewerbe | zwanzig bis sechzig Euro Gewerbeanmeldung jeder Gesellschafter meldet einzeln an | etwa null Euro nur Steuerberater optional |
    | GbR | Notar und Handelsregister dreihundert bis fünfhundert Euro | Gesellschaftervertrag empfohlen Anwalt eintausend |
    """

    // MARK: - The point of the feature

    /// The whole reason this exists: a table whose cells wrap must now stay a
    /// grid instead of falling back to raw pipes.
    @Test func aWrappingTableGoesLive() throws {
        let styled = try styleLive(wrappingTable)
        #expect(styled.layout.geometry.rowContentHeights.contains {
            $0 > styled.layout.singleLineHeight + 0.5
        }, "fixture must actually wrap, or this proves nothing")
        #expect(MarkdownStyler.canGoLive(
            layout: styled.layout, rows: styled.rows, availableWidth: availableWidth,
            text: styled.text, registry: MarkdownEditorConfiguration.default.extensionRegistry
        ))
        #expect(!renders(styled).isEmpty)
    }

    /// The reserved paragraph height has to equal the measured row, or the
    /// document's text jumps when the caret enters the table.
    @Test func reservedHeightMatchesTheMeasuredGrid() throws {
        let styled = try styleLive(wrappingTable)
        let geometry = styled.layout.geometry

        for render in renders(styled) {
            guard let row = render.geometryRow else {
                #expect(render.rowHeight == geometry.borderWidth, "delimiter collapses to a hairline")
                continue
            }
            #expect(render.rowHeight == geometry.rowPitch(row))
        }

        // And the sum of the reserved rows is the table's own height.
        let total = renders(styled).reduce(0) { $0 + $1.rowHeight }
        #expect(abs(total - geometry.totalSize.height) < 1.5,
                "reserved \(total) vs measured \(geometry.totalSize.height)")
    }

    /// A wrapped cell must report more than one line, or the fragment would draw
    /// one line into a box reserved for two.
    @Test func wrappedCellsCarryTheirLines() throws {
        let styled = try styleLive(wrappingTable)
        let multi = renders(styled)
            .flatMap(\.cells)
            .filter { $0.lineCount > 1 }
        #expect(!multi.isEmpty, "expected at least one wrapped cell")
        for cell in multi {
            #expect(cell.height == CGFloat(cell.lineCount) * cell.lineHeight)
        }
    }

    /// Every row gets a render, including the delimiter — a gap would leave a
    /// row drawn by nobody.
    @Test func everyRowCarriesARender() throws {
        let styled = try styleLive(wrappingTable)
        #expect(renders(styled).count == styled.rows.count)
        #expect(renders(styled).filter(\.isDelimiter).count == 1)
        #expect(renders(styled).filter(\.isHeader).count == 1)
    }

    // MARK: - Storage identity

    /// The whole design rests on this: styling changes attributes only. A single
    /// added or removed character would drift find, copy and undo.
    @Test func stylingLeavesTheDocumentTextUntouched() throws {
        let text = wrappingTable
        let styled = try styleLive(text)
        let storage = NSTextStorage(string: text)
        for (range, dict) in styled.attrs {
            for (key, value) in dict { storage.addAttribute(key, value: value, range: range) }
        }
        #expect(storage.string == text)
    }

    /// The source characters are hidden by SIZE. Hiding by colour alone would
    /// come back opaque under a selection, printing the raw pipes over the grid.
    @Test func tableCharactersAreHiddenBySize() throws {
        let styled = try styleLive(wrappingTable)
        let tableWide = try #require(styled.attrs.first { $0.range.length > 20 })
        let font = try #require(tableWide.attributes[.font] as? NSFont)
        #expect(font.pointSize < 1)
    }

    // MARK: - Cells

    /// Cell layouts must point at the DOCUMENT, so a click resolves to the right
    /// character of the real text rather than an offset into a detached string.
    @Test func cellLayoutsCarryDocumentOffsets() throws {
        let styled = try styleLive(wrappingTable)
        for render in renders(styled) {
            for cell in render.cells {
                #expect(cell.sourceLocation >= 0)
                #expect(cell.sourceLocation + cell.attributed.length <= styled.text.length)
                let source = styled.text.substring(
                    with: NSRange(location: cell.sourceLocation, length: cell.attributed.length)
                )
                #expect(source == cell.attributed.string,
                        "cell layout text must be the document's own characters")
            }
        }
    }

    /// A cell is wrapped at its column's content width — the same width the
    /// bitmap measured, or the two forms would break at different words.
    @Test func cellsWrapAtTheirColumnWidth() throws {
        let styled = try styleLive(wrappingTable)
        let geometry = styled.layout.geometry
        for render in renders(styled) where !render.isDelimiter {
            for (column, cell) in render.cells.enumerated() {
                guard let left = geometry.contentLeft(column),
                      let right = geometry.contentRight(column) else { continue }
                #expect(abs(cell.width - (right - left)) < 0.01)
            }
        }
    }

    // MARK: - Narrow tables still work

    @Test func aNonWrappingTableStillGoesLive() throws {
        let styled = try styleLive("| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(MarkdownStyler.canGoLive(
            layout: styled.layout, rows: styled.rows, availableWidth: availableWidth,
            text: styled.text, registry: MarkdownEditorConfiguration.default.extensionRegistry
        ))
        for render in renders(styled) where !render.isDelimiter {
            for cell in render.cells { #expect(cell.lineCount == 1) }
        }
    }

    // MARK: - Refusals that remain

    /// Emphasis, code and extension spans are styled in place now — the markers
    /// keep their characters and shrink, so offsets still map to the document.
    @Test func cellsWithEmphasisAndCodeGoLive() throws {
        let styled = try styleLive("| **bold** | `code` |\n|---|---|\n| *a* | plain |")
        #expect(MarkdownStyler.canGoLive(
            layout: styled.layout, rows: styled.rows, availableWidth: availableWidth,
            text: styled.text, registry: MarkdownEditorConfiguration.default.extensionRegistry
        ))
        // The markers must still be present as characters, or a click inside the
        // cell would resolve to the wrong document offset.
        for render in renders(styled) {
            for cell in render.cells {
                let source = styled.text.substring(
                    with: NSRange(location: cell.sourceLocation, length: cell.attributed.length)
                )
                #expect(source == cell.attributed.string)
            }
        }
    }

    /// A marker is hidden by size, not removed — that is what keeps the offsets
    /// honest while the drawn width still matches the picture.
    @Test func emphasisMarkersAreShrunkNotDropped() throws {
        let styled = try styleLive("| **bold** | b |\n|---|---|\n| 1 | 2 |")
        let cell = try #require(renders(styled).first?.cells.first)
        #expect(cell.attributed.string == "**bold**")
        let markerFont = try #require(cell.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let contentFont = try #require(cell.attributed.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        #expect(markerFont.pointSize < 1, "the `**` must be shrunk")
        #expect(contentFont.pointSize > 1, "the word must not be")
        #expect(contentFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    /// LaTeX becomes an attachment in the bitmap and has no source character to
    /// draw in the live form, so those cells keep the raw-source fallback.
    @Test func refusesCellsThatRenderAsAttachments() throws {
        let styled = try styleLive("| $x^2$ | b |\n|---|---|\n| 1 | 2 |")
        #expect(!MarkdownStyler.canGoLive(
            layout: styled.layout, rows: styled.rows, availableWidth: availableWidth,
            text: styled.text, registry: MarkdownEditorConfiguration.default.extensionRegistry
        ))
    }

    /// A table wider than the container goes live like any other and is panned
    /// inside the column. It used to refuse and drop to raw pipes, because the
    /// only wide form was a picture in a scroll view — so clicking the one kind
    /// of table hardest to read showed markup instead of the table.
    @Test func goesLiveEvenWiderThanTheContainer() throws {
        let header = (0..<14).map { "spaltenüberschrift\($0)" }.joined(separator: " | ")
        let delim = (0..<14).map { _ in "---" }.joined(separator: "|")
        let body = (0..<14).map { "sehrlangerzellenwert\($0)" }.joined(separator: " | ")
        let styled = try styleLive("| \(header) |\n|\(delim)|\n| \(body) |", width: 300)
        #expect(styled.layout.geometry.totalSize.width > 300, "test table must actually overflow")
        #expect(MarkdownStyler.canGoLive(
            layout: styled.layout, rows: styled.rows, availableWidth: 300,
            text: styled.text, registry: MarkdownEditorConfiguration.default.extensionRegistry
        ))
    }
}

// MARK: - Typing a space at the end of a cell

/// A space typed at the end of a cell lands in the padding OUTSIDE the trimmed
/// cell text. Judging the caret on the trimmed range clamped it back onto the
/// last letter, so the character reached the file while the caret stood still —
/// which reads as the space being swallowed.
@Suite("Live table cell padding")
struct LiveTableCellPaddingTests {
    private func cell(_ source: String, width: CGFloat = 200) -> LiveTableCellLayout {
        let ns = source as NSString
        let open = ns.range(of: "|").location
        let close = ns.range(of: "|", options: .backwards).location
        let span = NSRange(location: open + 1, length: close - open - 1)
        let text = ns.substring(with: span)
        let trimmedFront = text.count - text.drop(while: { $0 == " " }).count
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let font = NSFont.systemFont(ofSize: 15)
        return LiveTableCellLayout.make(
            attributed: NSAttributedString(string: trimmed, attributes: [.font: font]),
            sourceLocation: span.location + trimmedFront,
            width: width,
            lineHeight: 18,
            caretRange: span,
            font: font
        )
    }

    @Test func theCaretAdvancesIntoTrailingPadding() throws {
        let layout = cell("| ab  |")
        let end = layout.sourceLocation + layout.attributed.length
        let atText = try #require(layout.caretRect(forOffset: end, alignment: .left))
        let afterSpace = try #require(layout.caretRect(forOffset: end + 1, alignment: .left))
        #expect(afterSpace.minX > atText.minX,
                "a space typed at the end of a cell has to move the caret")
    }

    @Test func paddingBeforeTheTextCollapsesOntoIt() throws {
        let layout = cell("|   ab |")
        let start = try #require(layout.caretRect(forOffset: layout.caretRange.location, alignment: .left))
        let atText = try #require(layout.caretRect(forOffset: layout.sourceLocation, alignment: .left))
        #expect(start.minX == atText.minX)
    }

    /// The measurement underneath it: an advance counts trailing whitespace,
    /// the inked width must not.
    @Test func advanceCountsTrailingSpaceAndInkDoesNot() {
        let font = NSFont.systemFont(ofSize: 15)
        let bare = NSAttributedString(string: "ab", attributes: [.font: font])
        let padded = NSAttributedString(string: "ab ", attributes: [.font: font])
        #expect(LiveTableCellLayout.advance(of: padded) > LiveTableCellLayout.advance(of: bare))
    }
}

/// Which side of a soft wrap the caret sits on. The offset is the same
/// character either way, so only where the caret CAME FROM distinguishes them —
/// typing rightwards into the break has to stay on the line being filled.
@Suite("Live table caret affinity")
struct LiveTableCaretAffinityTests {
    private func wrapped() -> LiveTableCellLayout {
        let font = NSFont.systemFont(ofSize: 15)
        return LiveTableCellLayout.make(
            attributed: NSAttributedString(
                string: "einzelunternehmen kleingewerbe anmeldung", attributes: [.font: font]
            ),
            sourceLocation: 100, width: 120, lineHeight: 18, font: font
        )
    }

    @Test func typingIntoTheBreakStaysOnTheFilledLine() throws {
        let cell = wrapped()
        try #require(cell.lineCount > 1)
        let boundary = cell.sourceLocation + NSMaxRange(cell.lineRanges[0])
        let down = try #require(cell.caretRect(forOffset: boundary, alignment: .left))
        let up = try #require(cell.caretRect(forOffset: boundary, alignment: .left, preferUpstream: true))
        #expect(up.minY < down.minY, "upstream belongs on the earlier line")
        #expect(up.minX > down.minX, "and at its end, not at the next line's start")
    }

    /// Without a preference the caret still lands on the line the break spills
    /// into — that is what keeps ↑ from stepping out of the cell.
    @Test func theDefaultRemainsDownstream() throws {
        let cell = wrapped()
        let boundary = cell.sourceLocation + NSMaxRange(cell.lineRanges[0])
        let rect = try #require(cell.caretRect(forOffset: boundary, alignment: .left))
        #expect(rect.minY == cell.lineHeight)
    }

    /// The upstream caret sits after the last WORD. A wrap that broke on a
    /// space keeps that space in the line's range, and measuring it would park
    /// the caret a space out past the text.
    @Test func upstreamDoesNotOvershootTheLine() throws {
        let cell = wrapped()
        let boundary = cell.sourceLocation + NSMaxRange(cell.lineRanges[0])
        let rect = try #require(cell.caretRect(forOffset: boundary, alignment: .left, preferUpstream: true))
        let full = LiveTableCellLayout.advance(of: cell.attributed.attributedSubstring(from: cell.lineRanges[0]))
        #expect(rect.minX <= ceil(full))
    }
}

/// ⇧↵ in a cell. A table row is one line of the document, so the break is
/// written as `<br>`; both forms of the table have to turn it back into a line,
/// and — the load-bearing half — the row must reserve the taller height, or the
/// live grid draws over the row below it.
@Suite("Live table hard breaks")
struct LiveTableHardBreakTests {
    private let availableWidth: CGFloat = 650

    private func styled(_ text: String) throws -> (renders: [LiveTableRowRender], layout: MarkdownStyler.TableLayout) {
        _ = NSApplication.shared
        let font = NSFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: MarkdownTokenizer.parseTokensViaAST(in: text),
            codeTokens: [], activeTokenIndices: [], baseFont: font, layoutBridge: nil,
            baseDefaultLineHeight: 18, codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: NSFont.systemFont(ofSize: 0.1),
            configuration: .default, wikiLinkIDProvider: { _ in nil }
        )
        ctx.scopeBounds = nil
        let token = try #require(ctx.tokens.first { $0.kind == .table })
        let parsed = try #require(MarkdownStyler.parseTableSource(ctx.nsText.substring(with: token.range)))
        let layout = MarkdownStyler.measureTable(
            parsed, baseFont: font, theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
            availableWidth: availableWidth, extensions: ctx.configuration.extensions
        )
        var attrs: [StyledRange] = []
        MarkdownStyler.styleLiveTable(
            tableRange: token.range, layout: layout,
            rows: TableCells.rows(in: ctx.nsText, tableRange: token.range),
            ctx: ctx, attrs: &attrs
        )
        return (attrs.compactMap { $0.attributes[.liveTableRow] as? LiveTableRowRender }, layout)
    }

    @Test func aBreakSplitsTheCellInTwo() throws {
        let plain = try styled("| a | b |\n|---|---|\n| eins zwei | x |")
        let broken = try styled("| a | b |\n|---|---|\n| eins<br>zwei | x |")
        let plainCell = try #require(plain.renders.last?.cells.first)
        let brokenCell = try #require(broken.renders.last?.cells.first)
        #expect(plainCell.lineCount == 1)
        #expect(brokenCell.lineCount == 2)
    }

    /// The break's markup draws nothing, so it must not widen the cell either.
    @Test func theMarkupTakesNoWidth() throws {
        let broken = try styled("| a | b |\n|---|---|\n| eins<br>zwei | x |")
        let cell = try #require(broken.renders.last?.cells.first)
        let first = try #require(cell.lineRanges.first)
        // The `<br>` rides on the line it ends, so that line is longer in
        // characters than the word it shows.
        #expect(first.length > 4)
        let inked = LiveTableCellLayout.advance(of: cell.attributed.attributedSubstring(from: first))
        let word = LiveTableCellLayout.advance(
            of: cell.attributed.attributedSubstring(from: NSRange(location: 0, length: 4))
        )
        #expect(abs(inked - word) < 0.5, "the markup must add no advance")
    }

    /// The picture and the live grid have to agree on the row's height, or one
    /// of them overlaps its neighbour.
    @Test func theRowReservesTheTallerHeight() throws {
        let broken = try styled("| a | b |\n|---|---|\n| eins<br>zwei | x |")
        let total = broken.renders.reduce(0) { $0 + $1.rowHeight }
        #expect(abs(total - broken.layout.geometry.totalSize.height) < 1.5,
                "reserved \(total) vs measured \(broken.layout.geometry.totalSize.height)")
    }

    @Test func onlyRealBreakMarkupCounts() {
        #expect(TableCells.hardBreaks(in: "a<br>b").count == 1)
        #expect(TableCells.hardBreaks(in: "a<BR/>b").count == 1)
        #expect(TableCells.hardBreaks(in: "a<br />b").count == 1)
        #expect(TableCells.hardBreaks(in: "brand <brand> <br").isEmpty)
    }
}

/// The caret after ⇧↵. `make` extends the preceding line's range over the
/// `<br>` markup (every character must belong to a line, or hit-testing falls
/// through the gap), which manufactures the exact SHAPE of a soft wrap at an
/// offset that is not actually ambiguous. Treating it as one made the single
/// keypress whose purpose is "go to a new line" move the caret nowhere.
@Suite("Live table hard break caret")
struct LiveTableHardBreakCaretTests {
    private func cell(_ text: String) -> LiveTableCellLayout {
        let font = NSFont.systemFont(ofSize: 15)
        return LiveTableCellLayout.make(
            attributed: NSAttributedString(string: text, attributes: [.font: font]),
            sourceLocation: 100, width: 400, lineHeight: 18, font: font
        )
    }

    @Test func pastTheBreakIsAlwaysTheNewLine() throws {
        let layout = cell("eins<br>zwei")
        try #require(layout.lineCount == 2)
        let past = layout.sourceLocation + 8      // just after "eins<br>"
        // Typing moves the caret forward, which infers upstream affinity — the
        // right default at a soft wrap and wrong at every hard break.
        let up = try #require(layout.caretRect(forOffset: past, alignment: .left, preferUpstream: true))
        let down = try #require(layout.caretRect(forOffset: past, alignment: .left))
        #expect(up.minY == down.minY, "affinity must not apply across a hard break")
        #expect(up.minY == layout.lineHeight, "and the answer is the second line")
        #expect(up.minX == 0)
    }

    /// A soft wrap must keep its affinity — the earlier fix has to survive.
    @Test func aSoftWrapStillHonoursAffinity() throws {
        let layout = cell("einzelunternehmen kleingewerbe anmeldung sofort")
        let narrow = LiveTableCellLayout.make(
            attributed: layout.attributed, sourceLocation: 100, width: 120,
            lineHeight: 18, font: NSFont.systemFont(ofSize: 15)
        )
        try #require(narrow.lineCount > 1)
        #expect(narrow.hardTerminated.isEmpty)
        let boundary = narrow.sourceLocation + NSMaxRange(narrow.lineRanges[0])
        let up = try #require(narrow.caretRect(forOffset: boundary, alignment: .left, preferUpstream: true))
        let down = try #require(narrow.caretRect(forOffset: boundary, alignment: .left))
        #expect(up.minY < down.minY)
    }

    @Test func onlyTheBreakLineIsMarked() {
        let layout = cell("eins<br>zwei")
        #expect(layout.hardTerminated == [0])
    }
}

/// Raw syntax reveals for the construct the caret is in, exactly as it does in
/// prose. Everywhere else in the cell the markers stay kerned to zero, so the
/// live string keeps matching the width the picture measured.
@Suite("Live table marker reveal")
struct LiveTableMarkerRevealTests {

    private func cells(_ text: String, caret: Int) throws -> [LiveTableCellLayout] {
        _ = NSApplication.shared
        let font = NSFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: MarkdownTokenizer.parseTokensViaAST(in: text),
            codeTokens: [], activeTokenIndices: [], baseFont: font, layoutBridge: nil,
            baseDefaultLineHeight: 18, codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: NSFont.systemFont(ofSize: 0.1),
            configuration: .default, wikiLinkIDProvider: { _ in nil },
            caretLocation: caret
        )
        ctx.scopeBounds = nil
        let token = try #require(ctx.tokens.first { $0.kind == .table })
        let parsed = try #require(MarkdownStyler.parseTableSource(ctx.nsText.substring(with: token.range)))
        let layout = MarkdownStyler.measureTable(
            parsed, baseFont: font, theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
            availableWidth: 650, extensions: ctx.configuration.extensions
        )
        var attrs: [StyledRange] = []
        MarkdownStyler.styleLiveTable(
            tableRange: token.range, layout: layout,
            rows: TableCells.rows(in: ctx.nsText, tableRange: token.range),
            ctx: ctx, attrs: &attrs
        )
        return attrs.compactMap { $0.attributes[.liveTableRow] as? LiveTableRowRender }
            .flatMap(\.cells)
    }

    /// `| **fett** | b |` — the `**` is at 2…4 and 8…10.
    private let table = "| a | b |\n|---|---|\n| **fett** | plain |"

    private func markerIsVisible(_ cell: LiveTableCellLayout) throws -> Bool {
        let font = try #require(cell.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        return font.pointSize > 1
    }

    @Test func theCaretRevealsItsOwnConstruct() throws {
        // Caret inside the bold span.
        let inside = try cells(table, caret: 30)
        let cell = try #require(inside.first { $0.attributed.string == "**fett**" })
        #expect(try markerIsVisible(cell), "the ** must be readable while the caret is in it")
    }

    @Test func aCaretElsewhereLeavesItHidden() throws {
        let away = try cells(table, caret: 0)
        let cell = try #require(away.first { $0.attributed.string == "**fett**" })
        #expect(try !markerIsVisible(cell), "and hidden everywhere else")
    }

    /// The revealed cell is wider, so it can wrap onto a line the picture never
    /// measured. The row has to grow with it or the grid draws over the row below.
    @Test func aRevealedCellNeverOverflowsItsRow() throws {
        _ = NSApplication.shared
        let font = NSFont.systemFont(ofSize: 15)
        let geometry = TableGeometry(
            columnCount: 1, rowCount: 1,
            borderWidth: TableMetrics.borderWidth,
            cellHPadding: TableMetrics.cellHPadding,
            cellVPadding: TableMetrics.cellVPadding,
            columnLeft: [1, 121], rowTop: [1, 32], rowContentHeights: [19],
            alignments: [.left], totalSize: CGSize(width: 121, height: 32)
        )
        let tall = LiveTableCellLayout.make(
            attributed: NSAttributedString(string: "eins zwei drei vier fünf sechs sieben",
                                           attributes: [.font: font]),
            sourceLocation: 0, width: 96, lineHeight: 19, font: font
        )
        try #require(tall.lineCount > 1)
        let height = LiveTableRowRender.height(for: [tall], geometryRow: 0, geometry: geometry)
        #expect(height >= tall.height + 2 * geometry.cellVPadding)
        #expect(height > geometry.rowPitch(0) ?? 0, "a taller cell must push the row open")
    }
}
