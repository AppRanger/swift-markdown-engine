//
//  TableAnchorStampTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  A rendered table is found by scanning `.tableAnchor` on its anchor char, not
//  by recomputing where `emitCollapsedAttrs` put the anchor. These pin that the
//  stamp is actually there — in both narrow and wide mode — and that the box it
//  carries describes the image it was rendered with.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table anchor stamp")
struct TableAnchorStampTests {

    private func styled(_ text: String) throws -> [StyledRange] {
        _ = NSApplication.shared
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let font = NSFont.systemFont(ofSize: 15)
        let context = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )
        return MarkdownStyler.styleTables(context)
    }

    private func anchor(in attributes: [StyledRange]) throws -> StyledRange {
        try #require(attributes.first { $0.attributes[.tableAnchor] != nil })
    }

    @Test func narrowTableStampsItsRender() throws {
        let attributes = try styled("| a | b |\n|---|---|\n| 1 | 2 |")
        let stamped = try anchor(in: attributes)
        #expect(stamped.range.length == 1, "the stamp belongs on the single anchor char")

        let anchorBox = try #require(stamped.attributes[.tableAnchor] as? TableAnchor)
        let render = anchorBox.render
        #expect(render.geometry.totalSize == render.image.size)
        #expect(render.geometry.columnCount == 2)
        #expect(render.geometry.rowCount == 2)
    }

    /// The wide path builds its anchor attributes separately, so it needs its own
    /// assertion or a refactor could stamp only the narrow one.
    @Test func wideTableStampsItsRenderToo() throws {
        // Many columns of long words: the per-column minimums cannot fit, which
        // is the only thing that pushes a table into scrollable mode.
        let header = (0..<12).map { "columnheading\($0)" }.joined(separator: " | ")
        let delim = (0..<12).map { _ in "---" }.joined(separator: "|")
        let body = (0..<12).map { "someverylongcellvalue\($0)" }.joined(separator: " | ")
        let text = "| \(header) |\n|\(delim)|\n| \(body) |"

        let attributes = try styled(text)
        let stamped = try anchor(in: attributes)
        #expect(stamped.attributes[.scrollableBlockNaturalWidth] != nil, "expected wide mode")

        let anchorBox = try #require(stamped.attributes[.tableAnchor] as? TableAnchor)
        let render = anchorBox.render
        #expect(render.geometry.totalSize == render.image.size)
        #expect(render.geometry.columnCount == 12)
    }

    /// The bar has to fit into the gap under the table, and the app cannot
    /// recompute it — `baseDefaultLineHeight` prefers the layout bridge's value.
    @Test func gapBelowIsStampedAndMatchesTheParagraphSpacing() throws {
        let attributes = try styled("| a | b |\n|---|---|\n| 1 | 2 |")
        let stamped = try anchor(in: attributes)
        let anchorBox = try #require(stamped.attributes[.tableAnchor] as? TableAnchor)
        #expect(anchorBox.gapBelow == 18 * 0.5)
    }

    /// A table the caret is inside shows raw source — no image, so nothing to
    /// hang an affordance off.
    @Test func activeTableStampsNothing() throws {
        _ = NSApplication.shared
        let text = "| a | b |\n|---|---|\n| 1 | 2 |"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let tableIndex = try #require(tokens.firstIndex { $0.kind == .table })
        let font = NSFont.systemFont(ofSize: 15)
        let context = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [tableIndex],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )
        let attributes = MarkdownStyler.styleTables(context)
        #expect(!attributes.contains { $0.attributes[.tableAnchor] != nil })
    }

    /// The stamped range is what the mutation inserts against, so it must be the
    /// TOKEN range — ending before the last row's newline — not the paragraph
    /// range, whose `NSMaxRange` would land past the terminator.
    @Test func stampedSourceRangeIsTheTokenRange() throws {
        let text = "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\ntrailing"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let tableToken = try #require(tokens.first { $0.kind == .table })

        let attributes = try styled(text)
        let stamped = try anchor(in: attributes)
        let anchorBox = try #require(stamped.attributes[.tableAnchor] as? TableAnchor)
        #expect(anchorBox.sourceRange == tableToken.range)

        let ns = text as NSString
        #expect(ns.character(at: NSMaxRange(anchorBox.sourceRange)) == 0x0A,
                "the token must stop before the newline that follows the last row")
    }

    /// Two identical tables must not collapse onto one identity, or a consumer
    /// keyed by it would place one affordance for both.
    @Test func duplicateTablesGetDistinctSourceIDs() throws {
        let table = "| a | b |\n|---|---|\n| 1 | 2 |"
        let attributes = try styled(table + "\n\nbetween\n\n" + table)
        let ids = attributes.compactMap { ($0.attributes[.tableAnchor] as? TableAnchor)?.sourceID }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    /// The existing width-change stamp shares the same anchor dictionary; adding
    /// keys must not have displaced it.
    @Test func widthChangeStampSurvivesAlongside() throws {
        let attributes = try styled("| a | b |\n|---|---|\n| 1 | 2 |")
        let stamped = try anchor(in: attributes)
        #expect(stamped.attributes[.scrollableBlockFullRange] != nil)
    }
}
