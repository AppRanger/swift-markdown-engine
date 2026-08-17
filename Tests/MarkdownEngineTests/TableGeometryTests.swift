//
//  TableGeometryTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  The measured geometry has to describe the SAME grid the bitmap draws — it is
//  what later places chrome and per-cell editors on a table. These pin the
//  agreement: total size against the real image, and the cell rects against the
//  border/padding arithmetic `drawCell` uses.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table geometry")
struct TableGeometryTests {

    private let source = """
    | surface | key | opens |
    |---|:---:|---:|
    | Search | Cmd O | overlay |
    | Graph | Cmd G | canvas |
    """

    private func render(
        _ source: String,
        availableWidth: CGFloat
    ) throws -> (image: NSImage, geometry: TableGeometry) {
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let font = NSFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: source as NSString,
            tokens: [],
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
        ctx.scopeBounds = nil
        let aqua = try #require(NSAppearance(named: .aqua))
        let result = MarkdownStyler.tableRender(
            for: source, parsed: parsed, ctx: ctx,
            appearance: aqua, availableWidth: availableWidth
        )
        return (result.render.image, result.render.geometry)
    }

    /// The one invariant everything else rests on: a consumer positions chrome
    /// from the geometry but sees the image's pixels.
    @Test func totalSizeMatchesTheRenderedImage() throws {
        for width in [200.0, 650.0, 4000.0] as [CGFloat] {
            let (image, geometry) = try render(source, availableWidth: width)
            #expect(geometry.totalSize == image.size, "width \(width)")
        }
    }

    @Test func countsCoverHeaderPlusBodyRows() throws {
        let (_, geometry) = try render(source, availableWidth: 650)
        #expect(geometry.columnCount == 3)
        #expect(geometry.rowCount == 3, "header + 2 body rows")
        #expect(geometry.bodyRowCountIsTwo)
        #expect(geometry.columnLeft.count == 4)
        #expect(geometry.rowTop.count == 4)
    }

    @Test func alignmentsSurviveIntoTheGeometry() throws {
        let (_, geometry) = try render(source, availableWidth: 650)
        #expect(geometry.alignments == [.left, .center, .right])
    }

    /// Cells tile the table left-to-right without gaps beyond the borders and
    /// without overlapping — the property a hit-test depends on.
    @Test func cellRectsTileWithoutOverlap() throws {
        let (_, geometry) = try render(source, availableWidth: 650)
        for row in 0..<geometry.rowCount {
            var previousMaxX: CGFloat?
            for column in 0..<geometry.columnCount {
                let rect = try #require(geometry.cellRect(row: row, column: column))
                #expect(rect.width > 0)
                #expect(rect.height > 0)
                #expect(geometry.bounds.contains(rect))
                if let previousMaxX {
                    // Exactly one border between two adjacent cells.
                    #expect(abs(rect.minX - previousMaxX - geometry.borderWidth) < 0.01)
                }
                previousMaxX = rect.maxX
            }
        }
    }

    /// The text rect must sit inside its cell box, inset by the padding the
    /// renderer actually uses.
    @Test func contentRectSitsInsideItsCellByThePadding() throws {
        let (_, geometry) = try render(source, availableWidth: 650)
        for row in 0..<geometry.rowCount {
            for column in 0..<geometry.columnCount {
                let cell = try #require(geometry.cellRect(row: row, column: column))
                let content = try #require(geometry.cellContentRect(row: row, column: column))
                #expect(abs(content.minX - (cell.minX + geometry.cellHPadding)) < 0.01)
                #expect(abs(content.minY - (cell.minY + geometry.cellVPadding)) < 0.01)
                #expect(content.maxX <= cell.maxX + 0.01)
            }
        }
    }

    @Test func hitTestingFindsTheCellItsRectDescribes() throws {
        let (_, geometry) = try render(source, availableWidth: 650)
        for row in 0..<geometry.rowCount {
            for column in 0..<geometry.columnCount {
                let rect = try #require(geometry.cellRect(row: row, column: column))
                let hit = try #require(geometry.cell(at: CGPoint(x: rect.midX, y: rect.midY)))
                #expect(hit.row == row)
                #expect(hit.column == column)
            }
        }
    }

    @Test func hitTestingRejectsPointsOutsideTheTable() throws {
        let (_, geometry) = try render(source, availableWidth: 650)
        #expect(geometry.cell(at: CGPoint(x: -1, y: 5)) == nil)
        #expect(geometry.cell(at: CGPoint(x: 5, y: -1)) == nil)
        #expect(geometry.cell(at: CGPoint(x: geometry.rightEdge + 1, y: 5)) == nil)
        #expect(geometry.cell(at: CGPoint(x: 5, y: geometry.bottomEdge + 1)) == nil)
    }

    @Test func edgesAreTheImageBounds() throws {
        let (image, geometry) = try render(source, availableWidth: 650)
        #expect(geometry.rightEdge == image.size.width)
        #expect(geometry.bottomEdge == image.size.height)
    }

    /// Wrapping grows rows instead of the table; the geometry has to report the
    /// taller rows, not the one-line heights.
    @Test func narrowWidthProducesTallerRows() throws {
        let wide = try render(source, availableWidth: 4000).geometry
        let narrow = try render(source, availableWidth: 200).geometry
        #expect(narrow.totalSize.width <= wide.totalSize.width)
        #expect(narrow.totalSize.height >= wide.totalSize.height)
    }
}

private extension TableGeometry {
    /// Spelled out so the count assertion reads as prose in the failure message.
    var bodyRowCountIsTwo: Bool { rowCount - 1 == 2 }
}
