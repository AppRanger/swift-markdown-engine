//
//  LiveTableCellLayoutTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  The live table draws its cells itself, so TextKit no longer knows where the
//  glyphs are — every caret position and every click inside a table is answered
//  by this one struct. A mistake here does not crash and does not look wrong; it
//  silently puts the caret in the wrong character. These tests pin the geometry
//  by round-tripping it against itself and by reading the drawn pixels back.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Live table cell layout")
struct LiveTableCellLayoutTests {

    private let font = NSFont.systemFont(ofSize: 15)
    private let lineHeight: CGFloat = 18

    /// Real cell content: German words the wrapper has to break at spaces, an
    /// unbreakable compound longer than any sane column, and the shapes a
    /// cost table actually holds.
    private static let cells = [
        "Gründungskosten für Gesellschafter",
        "Einzelunternehmen (Kleingewerbe)",
        "20–60€ Gewerbeanmeldung, jeder Gesellschafter meldet einzeln an",
        "Donaudampfschifffahrtsgesellschaftskapitän",
        "~0€, nur Steuerberater optional",
        "Grüße",
        "",
    ]

    private func styled(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private func layout(
        _ text: String,
        width: CGFloat,
        at location: Int = 0,
        lineHeight: CGFloat? = nil
    ) -> LiveTableCellLayout {
        _ = NSApplication.shared
        return LiveTableCellLayout.make(
            attributed: styled(text),
            sourceLocation: location,
            width: width,
            lineHeight: lineHeight ?? self.lineHeight
        )
    }

    private func naturalWidth(_ text: String) -> CGFloat {
        _ = NSApplication.shared
        return styled(text).size().width
    }

    private static let alignments: [MarkdownStyler.TableAlignment] = [.left, .center, .right]

    // MARK: - Wrapping

    @Test func textNarrowerThanItsColumnStaysOnOneLine() {
        let text = "Grüße"
        let cell = layout(text, width: naturalWidth(text) + 40)
        #expect(cell.lineCount == 1)
        #expect(cell.lineRanges == [NSRange(location: 0, length: (text as NSString).length)])
        #expect(cell.height == lineHeight)
    }

    @Test func anEmptyCellIsOneLineNotZero() {
        let cell = layout("", width: 120)
        #expect(cell.lineCount == 1, "a zero-height cell would collapse its row")
        #expect(cell.height == lineHeight)
        #expect(cell.lineRanges == [NSRange(location: 0, length: 0)])
    }

    /// Halving the column has to cost lines, and narrowing further may only ever
    /// add them — a non-monotonic wrap means the row height jitters as the table
    /// is resized.
    @Test func narrowerColumnsWrapOntoMoreLines() {
        let text = "20–60€ Gewerbeanmeldung, jeder Gesellschafter meldet einzeln an"
        let natural = naturalWidth(text)
        #expect(layout(text, width: natural + 20).lineCount == 1)
        #expect(layout(text, width: natural / 2).lineCount >= 2)

        var previous = 0
        for width in stride(from: natural, through: 60, by: -40) {
            let count = layout(text, width: width).lineCount
            #expect(count >= previous,
                    "width \(width) reported \(count) lines after \(previous) at the wider column")
            previous = count
        }
    }

    /// The wrap boundary itself: one point of column width decides the row's
    /// height, so the two sides of it are asserted rather than assumed.
    @Test func theWrapBoundaryIsWhereTheTextStopsFitting() {
        let text = "Kosten pro Jahr"
        let natural = naturalWidth(text)
        #expect(layout(text, width: ceil(natural)).lineCount == 1)
        #expect(layout(text, width: ceil(natural) - 2).lineCount == 2)
    }

    @Test func heightIsAlwaysLineCountTimesTheGivenLineHeight() {
        for text in Self.cells {
            for width in [40.0, 90.0, 150.0, 400.0] as [CGFloat] {
                for lh in [14.0, 18.0, 26.5] as [CGFloat] {
                    let cell = layout(text, width: width, lineHeight: lh)
                    #expect(cell.height == CGFloat(cell.lineCount) * lh,
                            "'\(text.prefix(16))' at \(width)/\(lh)")
                }
            }
        }
    }

    /// A line that overflows its column would draw straight through the next
    /// column's border. Trailing break whitespace is excluded — it hangs.
    @Test func noWrappedLineIsWiderThanItsColumn() {
        for text in Self.cells where !text.isEmpty {
            for width in [60.0, 120.0, 240.0] as [CGFloat] {
                let cell = layout(text, width: width)
                for (index, range) in cell.lineRanges.enumerated() {
                    let visible = visibleWidth(of: cell, line: index)
                    #expect(visible <= width + 0.5,
                            "'\(text.prefix(16))' line \(index) \(range) is \(visible)pt in a \(width)pt column")
                }
            }
        }
    }

    // MARK: - lineRanges

    /// Every offset conversion adds `range.location` to a within-line index, so
    /// a gap or an overlap between two lines silently maps clicks to the wrong
    /// character instead of failing.
    @Test func lineRangesPartitionTheCellExactly() {
        for text in Self.cells {
            let length = (text as NSString).length
            for width in [30.0, 60.0, 120.0, 240.0, 800.0] as [CGFloat] {
                let cell = layout(text, width: width)
                let label = "'\(text.prefix(16))' at \(width)"
                #expect(!cell.lineRanges.isEmpty, "\(label)")

                var next = 0
                for range in cell.lineRanges {
                    #expect(range.location == next, "\(label): \(range) does not start at \(next)")
                    #expect(range.length >= 0, "\(label): \(range) is negative")
                    next = NSMaxRange(range)
                }
                #expect(next == length, "\(label): covered \(next) of \(length)")
                #expect(cell.lineRanges.count == cell.lineCount, "\(label): count disagrees")

                let rebuilt = cell.lineRanges
                    .map { (text as NSString).substring(with: $0) }
                    .joined()
                #expect(rebuilt == text, "\(label): lines do not reassemble the cell")
            }
        }
    }

    @Test func onlyAnEmptyCellHasAnEmptyLine() {
        let cell = layout("Gründungskosten für Gesellschafter", width: 90)
        #expect(cell.lineRanges.allSatisfy { $0.length > 0 })
    }

    // MARK: - offset ⇄ caretRect

    /// The invariant the caret rests on: clicking exactly where the caret is
    /// drawn must select the offset that drew it. Two boundaries can sit within
    /// a point of each other (a combining mark, half a surrogate pair) — then
    /// the nearest-boundary answer is accepted as long as it is indistinguishable
    /// on screen.
    @Test func offsetRoundTripsAgainstTheCaretRect() throws {
        let texts = [
            "Gründungskosten für Gesellschafter",
            "20–60€ Gewerbeanmeldung, jeder Gesellschafter meldet einzeln an",
            "Donaudampfschifffahrtsgesellschaftskapitän",
        ]
        for text in texts {
            let length = (text as NSString).length
            for width in [60.0, 120.0, 200.0] as [CGFloat] {
                let cell = layout(text, width: width, at: 500)
                #expect(cell.lineCount > 1, "'\(text.prefix(16))' at \(width) must wrap to be worth testing")

                for alignment in Self.alignments {
                    for offset in 500...(500 + length) {
                        let rect = try #require(cell.caretRect(forOffset: offset, alignment: alignment),
                                                "no caret for \(offset)")
                        let back = cell.offset(at: CGPoint(x: rect.minX, y: rect.minY), alignment: alignment)
                        if back == offset { continue }
                        let backRect = try #require(cell.caretRect(forOffset: back, alignment: alignment))
                        #expect(abs(backRect.minX - rect.minX) <= 1.0 && backRect.minY == rect.minY,
                                "\(alignment) \(width)pt: \(offset) resolved to \(back) at \(backRect) not \(rect)")
                    }
                }
            }
        }
    }

    /// Centre and right derive each line's x from that line's own width, so the
    /// caret has to move with the alignment instead of staying on the left edge.
    @Test func alignmentMovesTheCaretAcrossTheColumn() throws {
        let text = "Grüße"
        let cell = layout(text, width: 200)
        let left = try #require(cell.caretRect(forOffset: 0, alignment: .left))
        let centre = try #require(cell.caretRect(forOffset: 0, alignment: .center))
        let right = try #require(cell.caretRect(forOffset: 0, alignment: .right))
        #expect(left.minX == 0)
        #expect(centre.minX > left.minX)
        #expect(right.minX > centre.minX)
        #expect(right.minX <= 200)
    }

    // MARK: - The second line

    /// The reason this whole layout exists: with the row collapsed to one line of
    /// invisible text, TextKit would answer every click with a first-line
    /// character. A point on the second drawn line must reach the second line's
    /// text.
    @Test func aPointOnTheSecondLineResolvesToTheSecondLine() throws {
        let text = "Gründungskosten für Gesellschafter"
        let cell = layout(text, width: 200, at: 500)
        #expect(cell.lineCount == 2)
        let second = cell.lineRanges[1]
        let secondStart = 500 + second.location
        let secondEnd = 500 + NSMaxRange(second)

        for alignment in Self.alignments {
            for x in stride(from: 0.0, through: 200.0, by: 10.0) {
                let offset = cell.offset(at: CGPoint(x: x, y: 1.5 * lineHeight), alignment: alignment)
                #expect(offset >= secondStart && offset <= secondEnd,
                        "\(alignment) x=\(x) fell to \(offset), outside \(secondStart)...\(secondEnd)")
            }

            // Not merely clamped to the line's edge: the middle of the second
            // line's own text has to come back.
            let middle = secondStart + second.length / 2
            let rect = try #require(cell.caretRect(forOffset: middle, alignment: alignment))
            #expect(rect.minY == lineHeight, "\(alignment): second line drawn at y \(rect.minY)")
            let hit = cell.offset(at: CGPoint(x: rect.minX, y: rect.midY), alignment: alignment)
            #expect(hit > secondStart && hit < secondEnd, "\(alignment): landed on \(hit)")
        }
    }

    // MARK: - Document offsets

    /// `offset(at:)` feeds a selection directly, so it owes document indices.
    /// Same cell, two locations, everything shifted by the delta and nothing else.
    @Test func offsetsAreDocumentOffsetsNotCellLocalOnes() throws {
        let text = "Gründungskosten für Gesellschafter"
        let length = (text as NSString).length
        let atZero = layout(text, width: 120, at: 0)
        let atFive = layout(text, width: 120, at: 500)
        #expect(atZero.lineRanges == atFive.lineRanges, "lineRanges stay cell-relative")

        for alignment in Self.alignments {
            for y in stride(from: 0.0, to: atZero.height, by: 6.0) {
                for x in stride(from: -20.0, through: 140.0, by: 20.0) {
                    let point = CGPoint(x: x, y: y)
                    let shifted = atFive.offset(at: point, alignment: alignment)
                    #expect(shifted == atZero.offset(at: point, alignment: alignment) + 500,
                            "\(alignment) \(point)")
                    #expect(shifted >= 500 && shifted <= 500 + length, "\(alignment) \(point) → \(shifted)")
                }
            }
            for offset in 0...length {
                #expect(atFive.caretRect(forOffset: offset + 500, alignment: alignment)
                        == atZero.caretRect(forOffset: offset, alignment: alignment))
            }
        }
    }

    // MARK: - Clamping

    @Test func pointsOutsideTheCellClampToItsEnds() {
        let text = "Gründungskosten für Gesellschafter"
        let length = (text as NSString).length
        let cell = layout(text, width: 200, at: 500)
        let first = cell.lineRanges[0]
        let last = cell.lineRanges[cell.lineCount - 1]

        // Above the cell → its very first offset.
        #expect(cell.offset(at: CGPoint(x: 5, y: -500), alignment: .left) == 500)
        // Below it → the last line, not a line that does not exist.
        #expect(cell.offset(at: CGPoint(x: 0, y: 5_000), alignment: .left) == 500 + last.location)
        #expect(cell.offset(at: CGPoint(x: 5_000, y: 5_000), alignment: .left) == 500 + length)
        // Left of a line → that line's start; right of it → that line's end.
        #expect(cell.offset(at: CGPoint(x: -500, y: 5), alignment: .left) == 500)
        #expect(cell.offset(at: CGPoint(x: 5_000, y: 5), alignment: .left) == 500 + NSMaxRange(first))
    }

    /// Nothing a click can produce may leave the cell — a stray offset would be
    /// applied to the document as a selection.
    @Test func everyPointInAndAroundTheCellMapsInsideIt() {
        let text = "20–60€ Gewerbeanmeldung, jeder Gesellschafter meldet einzeln an"
        let length = (text as NSString).length
        let cell = layout(text, width: 120, at: 500)
        for alignment in Self.alignments {
            for y in stride(from: -40.0, through: cell.height + 40, by: 7.0) {
                for x in stride(from: -40.0, through: 200.0, by: 11.0) {
                    let offset = cell.offset(at: CGPoint(x: x, y: y), alignment: alignment)
                    #expect(offset >= 500 && offset <= 500 + length,
                            "\(alignment) (\(x),\(y)) → \(offset)")
                }
            }
        }
    }

    @Test func caretRectRefusesOffsetsOutsideTheCell() {
        let text = "Gründungskosten"
        let length = (text as NSString).length
        let cell = layout(text, width: 200, at: 500)
        #expect(cell.caretRect(forOffset: 499, alignment: .left) == nil)
        #expect(cell.caretRect(forOffset: 0, alignment: .left) == nil)
        #expect(cell.caretRect(forOffset: 500 + length + 1, alignment: .left) == nil)
        #expect(cell.caretRect(forOffset: 500 + length, alignment: .left) != nil,
                "the offset after the last character is a caret position")
    }

    @Test func anEmptyCellStillAnswersTheCaret() throws {
        let cell = layout("", width: 100, at: 42)
        #expect(cell.offset(at: CGPoint(x: 50, y: 9), alignment: .center) == 42)
        let rect = try #require(cell.caretRect(forOffset: 42, alignment: .left))
        #expect(rect.minX == 0)
        #expect(rect.height == lineHeight)
        #expect(cell.caretRect(forOffset: 43, alignment: .left) == nil)
    }

    // MARK: - Drawing

    /// Ink is read back off a bitmap because the failure this guards against —
    /// the second line never being drawn, or being drawn on top of the first —
    /// is invisible to any assertion about the layout's own numbers.
    @Test func drawingCoversEveryLineItReports() throws {
        let text = "Gründungskosten für Gesellschafter"
        let origin = CGPoint(x: 10, y: 5)
        let width: CGFloat = 200
        let cell = layout(text, width: width, lineHeight: 20)
        #expect(cell.lineCount == 2)

        for alignment in Self.alignments {
            let ink = try render(cell, origin: origin, alignment: alignment,
                                 canvas: CGSize(width: width + 60, height: cell.height + 40))
            for line in 0..<cell.lineCount {
                let top = origin.y + CGFloat(line) * 20
                #expect(ink.count(in: top..<(top + 20)) > 0,
                        "\(alignment): line \(line) drew nothing")
            }
            #expect(ink.count(in: -1_000..<origin.y) == 0, "\(alignment): ink above the cell")
            #expect(ink.count(in: (origin.y + cell.height)..<1_000) == 0,
                    "\(alignment): ink below the reported height")
            #expect(try #require(ink.minX) >= origin.x - 0.5, "\(alignment): ink left of the column")
            #expect(try #require(ink.maxX) <= origin.x + width + 0.5, "\(alignment): ink past the column")
        }
    }

    @Test func rightAlignedTextIsDrawnFurtherRightThanLeftAligned() throws {
        let text = "Grüße"
        let cell = layout(text, width: 200)
        let canvas = CGSize(width: 220, height: 40)
        let left = try #require(try render(cell, origin: .zero, alignment: .left, canvas: canvas).minX)
        let centre = try #require(try render(cell, origin: .zero, alignment: .center, canvas: canvas).minX)
        let right = try render(cell, origin: .zero, alignment: .right, canvas: canvas)
        #expect(left < centre)
        #expect(try #require(right.minX) > centre)
        #expect(try #require(right.maxX) <= 200.5)
    }

    @Test func drawingAnEmptyCellIsANoOp() throws {
        let cell = layout("", width: 100)
        let ink = try render(cell, origin: .zero, alignment: .center,
                             canvas: CGSize(width: 100, height: 20))
        #expect(ink.total == 0)
    }

    // MARK: - Known defect

    /// A wrapped line keeps the space it broke on, and that space is measured
    /// into the line's width — so under `.right` and `.center` every line but the
    /// last is placed left of where the rendered bitmap puts it, and the table
    /// jumps the moment the caret enters. TextKit's own aligned typesetter hangs
    /// the break whitespace instead.
    /// Regression: a wrapped line was measured over its FULL range, which still
    /// holds the space it broke on, and `size()` measures trailing whitespace —
    /// so every wrapped line but the last sat a space-width too far left under
    /// `.right` (half of one under `.center`), and the table shifted the moment
    /// the caret entered it.
    @Test
    func wrappedLinesAlignOnTheirVisibleTextNotTheirBreakSpace() throws {
        // Both wrapped lines end in the same glyph, so their ink edges are
        // directly comparable — no side-bearing arithmetic in the assertion.
        let text = "Gründungskosten für Gesellschafter"
        let width: CGFloat = 200
        let lineHeight: CGFloat = 20
        let cell = layout(text, width: width, lineHeight: lineHeight)
        #expect(cell.lineCount == 2)
        let canvas = CGSize(width: width + 40, height: cell.height + 20)
        func band(_ line: Int) -> Range<CGFloat> {
            CGFloat(line) * lineHeight..<CGFloat(line + 1) * lineHeight
        }

        let right = try render(cell, origin: .zero, alignment: .right, canvas: canvas)
        let firstRight = try #require(right.maxX(in: band(0)))
        let lastRight = try #require(right.maxX(in: band(1)))
        #expect(abs(firstRight - lastRight) < 0.5,
                "right-aligned lines end at \(firstRight) and \(lastRight)")

        let centre = try render(cell, origin: .zero, alignment: .center, canvas: canvas)
        for line in 0..<cell.lineCount {
            let left = try #require(centre.minX(in: band(line)))
            let rightEdge = try #require(centre.maxX(in: band(line)))
            #expect(abs(left - (width - rightEdge)) < 1.0,
                    "centred line \(line) has margins \(left) and \(width - rightEdge)")
        }
    }

    // MARK: - Helpers

    /// Width of a line's ink — the line range with trailing break whitespace
    /// dropped, which is what the reader sees.
    private func visibleWidth(of cell: LiveTableCellLayout, line: Int) -> CGFloat {
        let range = cell.lineRanges[line]
        let string = cell.attributed.string as NSString
        var end = NSMaxRange(range)
        while end > range.location,
              CharacterSet.whitespaces.contains(
                UnicodeScalar(string.character(at: end - 1)) ?? UnicodeScalar(0)) {
            end -= 1
        }
        let visible = NSRange(location: range.location, length: end - range.location)
        guard visible.length > 0 else { return 0 }
        return cell.attributed.attributedSubstring(from: visible).size().width
    }

    /// Where a draw actually put ink, in the same cell-local points the layout
    /// reports. Pixels are kept individually so a single line's band can be
    /// measured on its own — a line drawn in the wrong place is otherwise hidden
    /// by the extents of all the others.
    private struct Ink {
        /// One entry per inked pixel: its band (y) and its left and right edges.
        let pixels: [(y: CGFloat, left: CGFloat, right: CGFloat)]

        var total: Int { pixels.count }
        func count(in band: Range<CGFloat>) -> Int { pixels.filter { band.contains($0.y) }.count }
        func minX(in band: Range<CGFloat>) -> CGFloat? {
            pixels.filter { band.contains($0.y) }.map(\.left).min()
        }
        func maxX(in band: Range<CGFloat>) -> CGFloat? {
            pixels.filter { band.contains($0.y) }.map(\.right).max()
        }
        var minX: CGFloat? { pixels.map(\.left).min() }
        var maxX: CGFloat? { pixels.map(\.right).max() }
    }

    private func render(
        _ cell: LiveTableCellLayout,
        origin: CGPoint,
        alignment: MarkdownStyler.TableAlignment,
        canvas: CGSize
    ) throws -> Ink {
        _ = NSApplication.shared
        let image = NSImage(size: canvas, flipped: true) { _ in
            cell.draw(at: origin, alignment: alignment)
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let scale = CGFloat(rep.pixelsWide) / canvas.width

        var pixels: [(y: CGFloat, left: CGFloat, right: CGFloat)] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                pixels.append((y: CGFloat(y) / scale,
                               left: CGFloat(x) / scale,
                               right: CGFloat(x + 1) / scale))
            }
        }
        return Ink(pixels: pixels)
    }
}
