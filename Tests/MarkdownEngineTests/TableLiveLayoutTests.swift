//
//  TableLiveLayoutTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  The live (typeable) table form has to put each cell's glyphs where the
//  bitmap draws them, or the table visibly shifts the moment the caret enters
//  it. These lay the styled text out for real and measure the caret x of each
//  cell's first character against the measured grid.
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

    /// Style the table as live and lay the result out in a real TextKit 2 stack,
    /// so the assertions measure actual glyph positions rather than our own
    /// arithmetic played back.
    private func layout(_ text: String) throws -> (storage: NSTextStorage, geometry: TableGeometry) {
        _ = NSApplication.shared
        let ctx = context(for: text)
        let tableToken = try #require(ctx.tokens.first { $0.kind == .table })
        let parsed = try #require(MarkdownStyler.parseTableSource(ctx.nsText.substring(with: tableToken.range)))

        let tableLayout = MarkdownStyler.measureTable(
            parsed,
            baseFont: ctx.baseFont,
            theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor,
            latex: ctx.services.latex,
            availableWidth: availableWidth,
            extensions: ctx.configuration.extensions
        )
        let rows = TableCells.rows(in: ctx.nsText, tableRange: tableToken.range)
        #expect(MarkdownStyler.canGoLive(
            layout: tableLayout, rows: rows,
            availableWidth: availableWidth, text: ctx.nsText,
            registry: ctx.configuration.extensionRegistry
        ), "fixture must be live-able")

        var attrs: [StyledRange] = []
        MarkdownStyler.styleLiveTable(
            tableRange: tableToken.range, layout: tableLayout,
            rows: rows, ctx: ctx, attrs: &attrs
        )

        let storage = NSTextStorage(string: text)
        storage.setAttributes([.font: ctx.baseFont], range: NSRange(location: 0, length: storage.length))
        for (range, dict) in attrs {
            for (key, value) in dict { storage.addAttribute(key, value: value, range: range) }
        }
        return (storage, tableLayout.geometry)
    }

    /// x of the caret immediately before `location`, measured by TextKit.
    private func caretX(in storage: NSTextStorage, at location: Int) -> CGFloat {
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 10_000, height: 10_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: location)
        let point = manager.location(forGlyphAt: glyph)
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        storage.removeLayoutManager(manager)
        return fragment.minX + point.x
    }

    private func lineStart(in storage: NSTextStorage, line: Int) -> Int {
        let ns = storage.string as NSString
        var start = 0
        var seen = 0
        while seen < line {
            let range = ns.lineRange(for: NSRange(location: start, length: 0))
            start = NSMaxRange(range)
            seen += 1
        }
        return start
    }

    // MARK: - Column positions

    /// The load-bearing assertion: every cell's first glyph sits on the x the
    /// measured grid says it should, for all three column alignments.
    @Test func cellsLandOnTheMeasuredColumnEdges() throws {
        let text = """
        | surface | key | opens |
        |:---|:---:|---:|
        | Search | CmdO | overlay |
        | Graph | CmdG | canvas |
        """
        let (storage, geometry) = try layout(text)
        let ns = storage.string as NSString
        let rows = TableCells.rows(in: ns, tableRange: NSRange(location: 0, length: ns.length))
        let bold = NSFont(
            descriptor: NSFont.systemFont(ofSize: 15).fontDescriptor.withSymbolicTraits(.bold),
            size: 15
        ) ?? NSFont.systemFont(ofSize: 15)

        for row in rows where row.index != 1 {
            let geometryRow = row.index == 0 ? 0 : row.index - 1
            for (column, cell) in row.cells.enumerated() where cell.length > 0 {
                let font = geometryRow == 0 ? bold : NSFont.systemFont(ofSize: 15)
                let width = HeadingHelpers.textWidth(ns.substring(with: cell), font: font)
                let expected = try #require(
                    geometry.alignedX(row: geometryRow, column: column, textWidth: width)
                )
                let actual = caretX(in: storage, at: cell.location)
                #expect(abs(actual - expected) < 0.5,
                        "row \(row.index) col \(column): expected \(expected), got \(actual)")
            }
        }
    }

    /// Right-aligned columns are where a mistake in the kern chain shows first,
    /// because the target depends on the text's own width.
    @Test func rightAlignedColumnEndsAtItsContentEdge() throws {
        let text = """
        | a | value |
        |---|---:|
        | 1 | 42 |
        """
        let (storage, geometry) = try layout(text)
        let ns = storage.string as NSString
        let rows = TableCells.rows(in: ns, tableRange: NSRange(location: 0, length: ns.length))
        let body = try #require(rows.last)
        let cell = body.cells[1]
        let width = HeadingHelpers.textWidth(ns.substring(with: cell), font: NSFont.systemFont(ofSize: 15))
        let expectedRight = try #require(geometry.contentRight(1))
        let actualRight = caretX(in: storage, at: cell.location) + width
        #expect(abs(actualRight - expectedRight) < 0.5)
    }

    // MARK: - Storage identity

    /// The whole design rests on this: styling changes attributes only. If a
    /// character were added or removed here, find, copy and undo would all drift.
    @Test func stylingLeavesTheDocumentTextUntouched() throws {
        let text = """
        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let (storage, _) = try layout(text)
        #expect(storage.string == text)
    }

    // MARK: - Refusals

    @Test func refusesATableWhoseRowsWrap() throws {
        _ = NSApplication.shared
        let long = String(repeating: "wordy ", count: 60)
        let text = "| a | b |\n|---|---|\n| \(long) | x |"
        let ctx = context(for: text)
        let token = try #require(ctx.tokens.first { $0.kind == .table })
        let parsed = try #require(MarkdownStyler.parseTableSource(ctx.nsText.substring(with: token.range)))
        let tableLayout = MarkdownStyler.measureTable(
            parsed, baseFont: ctx.baseFont, theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
            availableWidth: availableWidth, extensions: ctx.configuration.extensions
        )
        let rows = TableCells.rows(in: ctx.nsText, tableRange: token.range)
        #expect(!MarkdownStyler.canGoLive(
            layout: tableLayout, rows: rows,
            availableWidth: availableWidth, text: ctx.nsText,
            registry: ctx.configuration.extensionRegistry
        ), "a wrapping table must keep the raw-source form")
    }

    /// Inline constructs are not styled inside a live cell yet, so a table
    /// containing one must not go live — it would show its raw markers at a
    /// width the grid did not measure.
    @Test func refusesCellsWithInlineConstructs() throws {
        _ = NSApplication.shared
        let text = "| **bold** | b |\n|---|---|\n| 1 | 2 |"
        let ctx = context(for: text)
        let token = try #require(ctx.tokens.first { $0.kind == .table })
        let parsed = try #require(MarkdownStyler.parseTableSource(ctx.nsText.substring(with: token.range)))
        let tableLayout = MarkdownStyler.measureTable(
            parsed, baseFont: ctx.baseFont, theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
            availableWidth: availableWidth, extensions: ctx.configuration.extensions
        )
        let rows = TableCells.rows(in: ctx.nsText, tableRange: token.range)
        #expect(!MarkdownStyler.canGoLive(
            layout: tableLayout, rows: rows,
            availableWidth: availableWidth, text: ctx.nsText,
            registry: ctx.configuration.extensionRegistry
        ))
    }
}
