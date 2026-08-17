//
//  LiveTableSelectionNavigationTests.swift
//  MarkdownEngineTests
//
//  `LiveTableSelectionNavigation` sits in the path of every click and every
//  arrow key in the editor, so the load-bearing assertion is the NEGATIVE one:
//  with no live table under the point, it must return exactly what the stock
//  navigation returns, and installing it must not disturb layout.
//
//  The positive half runs against a toy grid supplied through
//  `LiveTableGeometrySeam` — an invertible 2-line × n-column map, so a caret
//  offset and a point convert both ways and the arrow-key arithmetic is
//  checkable without a real table.
//
//  Headless: `textSelections(interactingAt:)` needs layout, not a window.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Live table selection navigation")
struct LiveTableSelectionNavigationTests {

    // MARK: - Harness

    /// Three paragraphs, each long enough to wrap in the 220pt container — so
    /// the layout snapshot below has both several fragments and several line
    /// fragments per fragment to disagree about.
    private nonisolated static let sample = """
        alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo lima
        mike november oscar papa quebec romeo sierra tango uniform victor whiskey
        xray yankee zulu one two three four five six seven eight nine ten eleven
        """

    private func makeTextView(_ text: String = sample, width: CGFloat = 220) -> NativeTextView {
        _ = NSApplication.shared
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        let font = NSFont.systemFont(ofSize: 14)
        tv.baseFont = font
        tv.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
        return tv
    }

    /// Every fragment's frame plus its line fragments' bounds — enough to catch
    /// a navigation object that perturbs layout rather than only reading it.
    private func layoutSnapshot(
        _ manager: NSTextLayoutManager
    ) -> [(frame: CGRect, lines: [CGRect])] {
        var result: [(frame: CGRect, lines: [CGRect])] = []
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            result.append((fragment.layoutFragmentFrame,
                           fragment.textLineFragments.map(\.typographicBounds)))
            return true
        }
        return result
    }

    /// Offsets of a selection's outer edges, which is all these tests compare —
    /// `NSTextSelection` has no useful equality.
    private func edges(_ selection: NSTextSelection?, in manager: NSTextLayoutManager) -> (Int, Int)? {
        guard let first = selection?.textRanges.first, let last = selection?.textRanges.last else { return nil }
        let start = manager.offset(from: manager.documentRange.location, to: first.location)
        let end = manager.offset(from: manager.documentRange.location, to: last.endLocation)
        return (start, end)
    }

    private func caret(at offset: Int, in manager: NSTextLayoutManager) -> NSTextSelection {
        let location = manager.location(manager.documentRange.location, offsetBy: offset)!
        return NSTextSelection(location, affinity: .downstream)
    }

    /// An invertible toy grid: `lines` rows of `columns` offsets, one offset per
    /// `columnWidth` points across and one line per `lineHeight` down, starting
    /// at `firstOffset`. Point → offset and offset → rect are exact inverses, so
    /// a failed assertion means the navigation arithmetic is wrong and not the
    /// fixture.
    private func toyGrid(
        frame: CGRect,
        firstOffset: Int,
        lines: Int = 2,
        columns: Int = 6,
        lineHeight: CGFloat = 20,
        columnWidth: CGFloat = 10
    ) -> LiveTableGeometrySeam {
        let cellRange = NSRange(location: firstOffset, length: lines * columns)
        return LiveTableGeometrySeam(
            hit: { point in
                guard frame.contains(point) else { return nil }
                let line = min(lines - 1, max(0, Int((point.y - frame.minY) / lineHeight)))
                let column = min(columns - 1, max(0, Int((point.x - frame.minX) / columnWidth)))
                return LiveTableHit(
                    offset: firstOffset + line * columns + column,
                    cellRange: cellRange
                )
            },
            caretRect: { offset in
                let local = offset - firstOffset
                guard local >= 0, local < lines * columns else { return nil }
                return CGRect(
                    x: frame.minX + CGFloat(local % columns) * columnWidth,
                    y: frame.minY + CGFloat(local / columns) * lineHeight,
                    width: 1,
                    height: lineHeight
                )
            }
        )
    }

    // MARK: - Installation

    /// The property is public and read/write, but "assignable" and "survives
    /// layout" are different claims — the second is the one the whole approach
    /// rests on.
    @Test func installingTheSubclassKeepsLayoutIntact() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)

        let before = layoutSnapshot(manager)
        #expect(before.count > 1, "several fragments, or this proves nothing")
        #expect(before.contains { $0.lines.count > 1 }, "the sample has to wrap, or this proves nothing")

        let navigation = LiveTableSelectionNavigation(dataSource: manager)
        manager.textSelectionNavigation = navigation
        #expect(manager.textSelectionNavigation === navigation)

        manager.invalidateLayout(for: manager.documentRange)
        manager.ensureLayout(for: manager.documentRange)
        let after = layoutSnapshot(manager)
        #expect(after.map(\.frame) == before.map(\.frame))
        #expect(after.map(\.lines) == before.map(\.lines))
    }

    // MARK: - Invisible outside a table

    @Test func aPointOutsideAnyTableMatchesStockNavigation() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let stock = NSTextSelectionNavigation(dataSource: manager)
        let ours = LiveTableSelectionNavigation(dataSource: manager)   // disconnected seam

        for point in [CGPoint(x: 4, y: 4), CGPoint(x: 90, y: 10), CGPoint(x: 150, y: 34), CGPoint(x: 30, y: 300)] {
            let expected = stock.textSelections(
                interactingAt: point, inContainerAt: manager.documentRange.location,
                anchors: [], modifiers: [], selecting: false, bounds: tv.bounds
            )
            let actual = ours.textSelections(
                interactingAt: point, inContainerAt: manager.documentRange.location,
                anchors: [], modifiers: [], selecting: false, bounds: tv.bounds
            )
            #expect(actual.count == expected.count)
            #expect(edges(actual.first, in: manager)! == edges(expected.first, in: manager)!,
                    "click at \(point) diverged from stock")
        }
    }

    @Test func doubleClickOutsideATableMatchesStockNavigation() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let stock = NSTextSelectionNavigation(dataSource: manager)
        let ours = LiveTableSelectionNavigation(dataSource: manager)
        let point = CGPoint(x: 60, y: 8)

        for granularity in [NSTextSelection.Granularity.word, .paragraph] {
            let expected = stock.textSelection(for: granularity, enclosing: point,
                                               inContainerAt: manager.documentRange.location)
            let actual = ours.textSelection(for: granularity, enclosing: point,
                                            inContainerAt: manager.documentRange.location)
            #expect(edges(actual, in: manager)! == edges(expected, in: manager)!)
        }
    }

    @Test func arrowKeysOutsideATableMatchStockNavigation() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let stock = NSTextSelectionNavigation(dataSource: manager)
        let ours = LiveTableSelectionNavigation(dataSource: manager)
        let selection = caret(at: 12, in: manager)

        for direction in [NSTextSelectionNavigation.Direction.down, .up, .right, .left] {
            let expected = stock.destinationSelection(
                for: selection, direction: direction, destination: .character,
                extending: false, confined: false
            )
            let actual = ours.destinationSelection(
                for: selection, direction: direction, destination: .character,
                extending: false, confined: false
            )
            #expect(edges(actual, in: manager)?.0 == edges(expected, in: manager)?.0,
                    "arrow \(direction.rawValue) diverged from stock")
        }
    }

    /// A rectangular (option-drag) selection has no meaning in a drawn grid, so
    /// it has to reach `super` even when the point IS in a live table.
    @Test func rectangularSelectionIsLeftToStockEvenInsideATable() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let stock = NSTextSelectionNavigation(dataSource: manager)
        let ours = LiveTableSelectionNavigation(
            dataSource: manager, seam: toyGrid(frame: frame, firstOffset: 30)
        )
        let point = CGPoint(x: 25, y: 10)

        let expected = stock.textSelections(
            interactingAt: point, inContainerAt: manager.documentRange.location,
            anchors: [], modifiers: [.visual], selecting: false, bounds: tv.bounds
        )
        let actual = ours.textSelections(
            interactingAt: point, inContainerAt: manager.documentRange.location,
            anchors: [], modifiers: [.visual], selecting: false, bounds: tv.bounds
        )
        #expect(edges(actual.first, in: manager)! == edges(expected.first, in: manager)!)
    }

    // MARK: - Inside a live table

    @Test func clickInsideALiveCellPlacesTheCaretWhereTheSeamSays() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let navigation = LiveTableSelectionNavigation(
            dataSource: manager, seam: toyGrid(frame: frame, firstOffset: 30)
        )

        // Line 1, column 3 → 30 + 1×6 + 3.
        let selections = navigation.textSelections(
            interactingAt: CGPoint(x: 35, y: 25), inContainerAt: manager.documentRange.location,
            anchors: [], modifiers: [], selecting: false, bounds: tv.bounds
        )
        #expect(selections.count == 1)
        #expect(edges(selections.first, in: manager)! == (39, 39))
    }

    /// Triple click must not run to the end of the source ROW: those characters
    /// are pipes and padding drawn nowhere near the highlight.
    @Test func granularityExpansionIsClampedToTheCell() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let navigation = LiveTableSelectionNavigation(
            dataSource: manager, seam: toyGrid(frame: frame, firstOffset: 30)
        )
        let point = CGPoint(x: 35, y: 25)   // offset 39, cell = 30..<42

        let stock = NSTextSelectionNavigation(dataSource: manager)
        let unclamped = stock.textSelection(for: .paragraph, enclosing: caret(at: 39, in: manager))
        #expect(edges(unclamped, in: manager)!.1 > 42, "nothing to clamp — fixture is wrong")

        let paragraph = navigation.textSelection(for: .paragraph, enclosing: point,
                                                 inContainerAt: manager.documentRange.location)
        #expect(edges(paragraph, in: manager)! == (30, 42))
        #expect(paragraph?.granularity == .paragraph, "AppKit reads the granularity back off the selection")

        let word = navigation.textSelection(for: .word, enclosing: point,
                                            inContainerAt: manager.documentRange.location)
        let bounds = try #require(edges(word, in: manager))
        #expect(bounds.0 >= 30 && bounds.1 <= 42)
    }

    @Test func dragExtendsFromTheFarEdgeOfTheAnchor() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let navigation = LiveTableSelectionNavigation(
            dataSource: manager, seam: toyGrid(frame: frame, firstOffset: 30)
        )
        let anchor = caret(at: 31, in: manager)

        // Drag right to line 0, column 5 → 35. The anchor stays put.
        let dragged = navigation.textSelections(
            interactingAt: CGPoint(x: 55, y: 5), inContainerAt: manager.documentRange.location,
            anchors: [anchor], modifiers: [], selecting: true, bounds: tv.bounds
        )
        #expect(edges(dragged.first, in: manager)! == (31, 35))

        // Shift-click BACK past the anchor keeps the far edge, so the selection
        // flips rather than collapsing.
        let extended = navigation.textSelections(
            interactingAt: CGPoint(x: 5, y: 5), inContainerAt: manager.documentRange.location,
            anchors: [dragged.first!], modifiers: [.extend], selecting: false, bounds: tv.bounds
        )
        #expect(edges(extended.first, in: manager)! == (30, 35))
    }

    @Test func verticalArrowStepsOneWrappedLineInsideTheCell() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let navigation = LiveTableSelectionNavigation(
            dataSource: manager, seam: toyGrid(frame: frame, firstOffset: 30)
        )

        // 32 = line 0, column 2 → down one line keeps the column: 38.
        let down = navigation.destinationSelection(
            for: caret(at: 32, in: manager), direction: .down,
            destination: .character, extending: false, confined: false
        )
        #expect(edges(down, in: manager)! == (38, 38))

        let up = navigation.destinationSelection(
            for: caret(at: 38, in: manager), direction: .up,
            destination: .character, extending: false, confined: false
        )
        #expect(edges(up, in: manager)! == (32, 32))
    }

    /// Stepping off the top of the grid is how the caret LEAVES a table, so it
    /// has to reach `super` — clamping would trap the caret in the table.
    @Test func steppingOffTheGridFallsBackToStock() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let stock = NSTextSelectionNavigation(dataSource: manager)
        let navigation = LiveTableSelectionNavigation(
            dataSource: manager, seam: toyGrid(frame: frame, firstOffset: 30)
        )
        let selection = caret(at: 32, in: manager)   // top line of the grid

        let expected = stock.destinationSelection(
            for: selection, direction: .up, destination: .character,
            extending: false, confined: false
        )
        let actual = navigation.destinationSelection(
            for: selection, direction: .up, destination: .character,
            extending: false, confined: false
        )
        #expect(edges(actual, in: manager)?.0 == edges(expected, in: manager)?.0)
    }

    @Test func verticalArrowExtendsFromTheEdgeItLeavesBehind() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let navigation = LiveTableSelectionNavigation(
            dataSource: manager, seam: toyGrid(frame: frame, firstOffset: 30)
        )

        let extended = navigation.destinationSelection(
            for: caret(at: 32, in: manager), direction: .down,
            destination: .character, extending: true, confined: false
        )
        #expect(edges(extended, in: manager)! == (32, 38))
    }

    // MARK: - A REAL live table, in a real text view

    /// Everything a test needs about one styled live table standing in a text
    /// view whose fragments are the engine's own.
    ///
    /// The toy grid above proves the navigation ARITHMETIC; this proves the
    /// installed seam is wired to the geometry that is actually drawn — the two
    /// failures it catches (a coordinate space off by the container origin, a
    /// seam pointed at nothing) are invisible to a fixture.
    private struct LiveFixture {
        let textView: NativeTextView
        let manager: NSTextLayoutManager
        let renders: [LiveTableRowRender]
        /// `NSTextLayoutManager.delegate` is weak; without this the fragments
        /// silently revert to stock ones and every live answer becomes nil.
        let delegate: MarkdownLayoutManagerDelegate
        /// Offset of the first character below the table's own paragraphs.
        let introRange: NSRange

        /// Body rows only — the header and the collapsed delimiter are not what
        /// a user types in.
        var bodyRows: [LiveTableRowRender] {
            renders.filter { !$0.isDelimiter && !$0.isHeader }
        }
    }

    /// Wraps in a 650pt column, and every cell is plain text — so the table
    /// goes live and each row draws more than one line.
    private nonisolated static let liveTableSource = """
        Intro paragraph above the table.

        | Rechtsform | Gründungskosten | Laufende Kosten |
        |---|---|---|
        | Einzelunternehmen Kleingewerbe | zwanzig bis sechzig Euro Gewerbeanmeldung jeder Gesellschafter meldet einzeln an | etwa null Euro nur Steuerberater optional |
        | GbR | Notar und Handelsregister dreihundert bis fünfhundert Euro | Gesellschaftervertrag empfohlen Anwalt eintausend |
        """

    private func makeLiveTable(width: CGFloat = 650) throws -> LiveFixture {
        _ = NSApplication.shared
        let source = Self.liveTableSource
        let ns = source as NSString
        let font = NSFont.systemFont(ofSize: 15)

        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        tv.baseFont = font
        let manager = try #require(tv.textLayoutManager)
        let container = try #require(tv.textContainer)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        let delegate = MarkdownLayoutManagerDelegate()
        manager.delegate = delegate

        var ctx = MarkdownStyler.StylingContext(
            nsText: ns,
            tokens: MarkdownTokenizer.parseTokensViaAST(in: source),
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

        let token = try #require(ctx.tokens.first { $0.kind == .table })
        let parsed = try #require(MarkdownStyler.parseTableSource(ns.substring(with: token.range)))
        let layout = MarkdownStyler.measureTable(
            parsed, baseFont: font, theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
            availableWidth: width, extensions: ctx.configuration.extensions
        )
        let rows = TableCells.rows(in: ns, tableRange: token.range)
        #expect(MarkdownStyler.canGoLive(
            layout: layout, rows: rows, availableWidth: width,
            text: ns, registry: MarkdownEditorConfiguration.default.extensionRegistry
        ), "fixture must actually go live, or every assertion below is vacuous")

        var attrs: [StyledRange] = []
        MarkdownStyler.styleLiveTable(
            tableRange: token.range, layout: layout, rows: rows, ctx: ctx, attrs: &attrs
        )

        let storage = try #require(tv.textStorage)
        storage.setAttributedString(NSAttributedString(
            string: source, attributes: [.font: font, .foregroundColor: NSColor.textColor]
        ))
        storage.beginEditing()
        for (range, attributes) in attrs { storage.addAttributes(attributes, range: range) }
        storage.endEditing()
        manager.ensureLayout(for: manager.documentRange)

        return LiveFixture(
            textView: tv,
            manager: manager,
            renders: attrs.compactMap { $0.attributes[.liveTableRow] as? LiveTableRowRender },
            delegate: delegate,
            introRange: NSRange(location: 0, length: token.range.location)
        )
    }

    /// The point the caret is DRAWN at for `offset`, nudged inside the glyph so
    /// a click resolves to that character and not the one before it.
    private func drawnPoint(for offset: Int, in fixture: LiveFixture) throws -> CGPoint {
        let rect = try #require(fixture.textView.liveTableCaretRect(forOffset: offset),
                                "offset \(offset) is not inside a live cell")
        return CGPoint(x: rect.minX + 1, y: rect.midY)
    }

    private func click(
        at point: CGPoint, on navigation: NSTextSelectionNavigation, in fixture: LiveFixture
    ) -> [NSTextSelection] {
        navigation.textSelections(
            interactingAt: point, inContainerAt: fixture.manager.documentRange.location,
            anchors: [], modifiers: [], selecting: false, bounds: fixture.textView.bounds
        )
    }

    /// The whole feature in one assertion: click where a cell's first character
    /// is drawn and the caret lands on that character — which stock navigation,
    /// answering from the invisible one-line row, does not.
    @Test func theInstalledSeamResolvesAClickToTheCellItWasDrawnIn() throws {
        let fixture = try makeLiveTable()
        fixture.textView.installLiveTableNavigationIfNeeded()
        let navigation = try #require(
            fixture.manager.textSelectionNavigation as? LiveTableSelectionNavigation
        )

        let row = try #require(fixture.bodyRows.last)
        let cell = try #require(row.cells.last)
        let point = try drawnPoint(for: cell.sourceLocation, in: fixture)

        let ours = try #require(edges(click(at: point, on: navigation, in: fixture).first,
                                      in: fixture.manager))
        #expect(ours.0 == cell.sourceLocation)

        let stock = NSTextSelectionNavigation(dataSource: fixture.manager)
        let theirs = try #require(edges(click(at: point, on: stock, in: fixture).first,
                                        in: fixture.manager))
        #expect(theirs.0 != ours.0, "stock agreeing means the point proves nothing")
    }

    /// Every cell, not just a lucky one: the caret rect and the hit test have to
    /// be exact inverses across the whole grid or clicking feels arbitrary.
    @Test func everyCellRoundTripsThroughTheSeam() throws {
        let fixture = try makeLiveTable()
        fixture.textView.installLiveTableNavigationIfNeeded()
        let navigation = try #require(
            fixture.manager.textSelectionNavigation as? LiveTableSelectionNavigation
        )

        var checked = 0
        for row in fixture.renders where !row.isDelimiter {
            for cell in row.cells {
                let point = try drawnPoint(for: cell.sourceLocation, in: fixture)
                let landed = try #require(edges(click(at: point, on: navigation, in: fixture).first,
                                                in: fixture.manager))
                #expect(landed.0 == cell.sourceLocation,
                        "cell at \(cell.sourceLocation) landed on \(landed.0)")
                checked += 1
            }
        }
        #expect(checked >= 9, "header + two body rows × three columns")
    }

    /// Above the table the seam has to be invisible — this is the whole editor.
    @Test func theInstalledSeamIsInvisibleOutsideTheTable() throws {
        let fixture = try makeLiveTable()
        let stock = NSTextSelectionNavigation(dataSource: fixture.manager)
        fixture.textView.installLiveTableNavigationIfNeeded()
        let navigation = try #require(
            fixture.manager.textSelectionNavigation as? LiveTableSelectionNavigation
        )

        for point in [CGPoint(x: 4, y: 4), CGPoint(x: 60, y: 6), CGPoint(x: 200, y: 10)] {
            let ours = try #require(edges(click(at: point, on: navigation, in: fixture).first,
                                          in: fixture.manager))
            let theirs = try #require(edges(click(at: point, on: stock, in: fixture).first,
                                            in: fixture.manager))
            #expect(ours == theirs, "click at \(point) diverged from stock")
            #expect(ours.0 <= NSMaxRange(fixture.introRange), "fixture point is not above the table")
        }

        let caret = self.caret(at: 5, in: fixture.manager)
        for direction in [NSTextSelectionNavigation.Direction.down, .up, .right, .left] {
            let ours = navigation.destinationSelection(
                for: caret, direction: direction, destination: .character,
                extending: false, confined: false
            )
            let theirs = stock.destinationSelection(
                for: caret, direction: direction, destination: .character,
                extending: false, confined: false
            )
            #expect(edges(ours, in: fixture.manager)?.0 == edges(theirs, in: fixture.manager)?.0,
                    "arrow \(direction.rawValue) diverged from stock")
        }
    }

    /// ↓ inside a wrapped cell has to step one DRAWN line and stay in the cell.
    /// TextKit would leave the row entirely — the whole row is one line to it.
    ///
    /// Asserted against the cell's own `lineRanges`, not against a caret rect
    /// round trip: `LiveTableCellLayout.caretRect(forOffset:)` resolves an
    /// offset that sits exactly ON a soft line break to the UPSTREAM line (see
    /// the reported defect), so the rect for the character this lands on claims
    /// the line above. The move itself is correct; only the read-back is not.
    @Test func arrowDownInsideAWrappedCellStepsOneDrawnLine() throws {
        let fixture = try makeLiveTable()
        fixture.textView.installLiveTableNavigationIfNeeded()
        let navigation = try #require(
            fixture.manager.textSelectionNavigation as? LiveTableSelectionNavigation
        )

        let wrapped = try #require(
            fixture.bodyRows.flatMap(\.cells).first { $0.lineCount > 1 },
            "fixture must contain a wrapped cell"
        )
        let start = wrapped.sourceLocation

        let moved = navigation.destinationSelection(
            for: caret(at: start, in: fixture.manager), direction: .down,
            destination: .character, extending: false, confined: false
        )
        let landed = try #require(edges(moved, in: fixture.manager)).0
        #expect(landed == start + wrapped.lineRanges[1].location,
                "↓ from the head of drawn line 0 must land on the head of drawn line 1")

        // Stepping down from the MIDDLE of line 0 (no boundary ambiguity) keeps
        // the column and drops exactly one line — the sticky-x path. The click
        // first is not decoration: a pointer interaction is what ends the arrow
        // run above and clears the sticky column, exactly as in the editor.
        let middle = start + wrapped.lineRanges[0].length / 2
        let middlePoint = try drawnPoint(for: middle, in: fixture)
        let clicked = try #require(edges(click(at: middlePoint, on: navigation, in: fixture).first,
                                         in: fixture.manager)).0
        let clickedRect = try #require(fixture.textView.liveTableCaretRect(forOffset: clicked))

        let below = navigation.destinationSelection(
            for: caret(at: clicked, in: fixture.manager), direction: .down,
            destination: .character, extending: false, confined: false
        )
        let belowOffset = try #require(edges(below, in: fixture.manager)).0
        #expect(belowOffset > start + wrapped.lineRanges[1].location, "did not reach into line 1")
        #expect(belowOffset <= start + wrapped.attributed.length, "left its own cell")
        let belowRect = try #require(fixture.textView.liveTableCaretRect(forOffset: belowOffset))
        #expect(abs(belowRect.minY - (clickedRect.minY + wrapped.lineHeight)) < 1,
                "moved \(belowRect.minY - clickedRect.minY)pt, one drawn line is \(wrapped.lineHeight)pt")
        #expect(abs(belowRect.minX - clickedRect.minX) < wrapped.lineHeight,
                "vertical arrows must hold the column")

        // And ↑ from there returns to the line it came from.
        let back = navigation.destinationSelection(
            for: caret(at: belowOffset, in: fixture.manager), direction: .up,
            destination: .character, extending: false, confined: false
        )
        let backOffset = try #require(edges(back, in: fixture.manager)).0
        let backRect = try #require(fixture.textView.liveTableCaretRect(forOffset: backOffset))
        #expect(abs(backRect.minY - clickedRect.minY) < 1)
    }

    /// Triple click on a cell selects the cell, not the source row: the pipes
    /// and padding either side are drawn nowhere near the highlight.
    @Test func doubleAndTripleClickStayInsideTheCell() throws {
        let fixture = try makeLiveTable()
        fixture.textView.installLiveTableNavigationIfNeeded()
        let navigation = try #require(
            fixture.manager.textSelectionNavigation as? LiveTableSelectionNavigation
        )

        let row = try #require(fixture.bodyRows.first)
        let cell = try #require(row.cells.dropFirst().first)
        let cellRange = NSRange(location: cell.sourceLocation, length: cell.attributed.length)
        let point = try drawnPoint(for: cell.sourceLocation + 2, in: fixture)

        for granularity in [NSTextSelection.Granularity.word, .paragraph] {
            let selection = navigation.textSelection(
                for: granularity, enclosing: point,
                inContainerAt: fixture.manager.documentRange.location
            )
            let bounds = try #require(edges(selection, in: fixture.manager))
            #expect(bounds.0 >= cellRange.location && bounds.1 <= NSMaxRange(cellRange),
                    "\(granularity) escaped the cell: \(bounds) vs \(cellRange)")
        }
    }

    // MARK: - Caret placement

    /// TextKit's own caret for an offset in a live row is a sliver on the
    /// invisible one-line row, at the far left. The indicator has to be moved
    /// onto the drawn cell instead — the second half of "usable".
    @Test func theCaretFrameIsTheDrawnCellNotTextKitsIdeaOfIt() throws {
        let fixture = try makeLiveTable()
        let row = try #require(fixture.bodyRows.last)
        let cell = try #require(row.cells.last)
        fixture.textView.setSelectedRange(NSRange(location: cell.sourceLocation, length: 0))

        let ours = try #require(fixture.textView.liveTableCaretIndicatorFrame(width: 2))
        let drawn = try #require(fixture.textView.liveTableCaretRect(forOffset: cell.sourceLocation))
        let origin = fixture.textView.textContainerOrigin
        #expect(ours.origin == CGPoint(x: drawn.minX + origin.x, y: drawn.minY + origin.y))
        #expect(ours.height == drawn.height)
        #expect(ours.width == 2, "the caret keeps AppKit's thickness")

        // What TextKit would have drawn, via the same segment enumeration the
        // block-image resize uses.
        let storage = try #require(fixture.manager.textContentManager as? NSTextContentStorage)
        let location = try #require(storage.location(storage.documentRange.location,
                                                     offsetBy: cell.sourceLocation))
        var stock: CGRect?
        fixture.manager.enumerateTextSegments(
            in: NSTextRange(location: location), type: .standard, options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            stock = frame
            return false
        }
        let textKit = try #require(stock)
        #expect(abs(textKit.minX - drawn.minX) > 20,
                "TextKit already agrees, so this cell proves nothing")
        // The row's paragraph forces the whole grid's height onto its one line,
        // so TextKit's caret is a bar as tall as the entire row. The drawn one
        // is one cell line tall, which is what a caret in a cell should be.
        #expect(abs(textKit.height - row.rowHeight) < 1)
        #expect(drawn.height < textKit.height - 1)
    }

    /// One paragraph up, nothing must be touched — the caret machinery is on
    /// the per-keystroke path for every document, table or not.
    @Test func theCaretFrameIsNilOutsideALiveTable() throws {
        let fixture = try makeLiveTable()
        fixture.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(fixture.textView.liveTableCaretIndicatorFrame(width: 2) == nil)

        // A range selection has no caret to place either.
        let cell = try #require(fixture.bodyRows.first?.cells.first)
        fixture.textView.setSelectedRange(NSRange(location: cell.sourceLocation, length: 3))
        #expect(fixture.textView.liveTableCaretIndicatorFrame(width: 2) == nil)
    }

    /// The O(1) gate in front of both seam answers has to agree with the
    /// expensive walk it is protecting, or clicks and carets go dead.
    @Test func theCheapGateAgreesWithTheGeometry() throws {
        let fixture = try makeLiveTable()
        #expect(fixture.textView.viewportHasLiveTableRow)

        for row in fixture.renders where !row.isDelimiter {
            for cell in row.cells {
                #expect(fixture.textView.liveTableRowRender(atOffset: cell.sourceLocation) != nil)
                #expect(fixture.textView.liveTableRowRender(
                    atOffset: cell.sourceLocation + cell.attributed.length) != nil,
                    "a cell's END offset is where a caret sits after ⌘→")
            }
        }
        for offset in [0, 3, fixture.introRange.length - 1] {
            #expect(fixture.textView.liveTableRowRender(atOffset: offset) == nil)
        }
    }

    // MARK: - Installation on the text view

    @Test func installingIsIdempotent() throws {
        let fixture = try makeLiveTable()
        fixture.textView.installLiveTableNavigationIfNeeded()
        let first = try #require(
            fixture.manager.textSelectionNavigation as? LiveTableSelectionNavigation
        )
        fixture.textView.installLiveTableNavigationIfNeeded()
        #expect(fixture.manager.textSelectionNavigation === first,
                "a second install would drop the sticky column mid-arrow-run")
    }

    /// Removing the seam must put the editor back exactly where it was — the
    /// escape hatch if the real-app run says AppKit does something unexpected.
    @Test func removingTheSeamRestoresStockNavigation() throws {
        let fixture = try makeLiveTable()
        let cell = try #require(fixture.bodyRows.last?.cells.last)
        let point = try drawnPoint(for: cell.sourceLocation, in: fixture)
        let before = try #require(edges(
            click(at: point, on: fixture.manager.textSelectionNavigation, in: fixture).first,
            in: fixture.manager
        ))

        fixture.textView.installLiveTableNavigationIfNeeded()
        let live = try #require(edges(
            click(at: point, on: fixture.manager.textSelectionNavigation, in: fixture).first,
            in: fixture.manager
        ))
        #expect(live != before, "install did nothing, so removal proves nothing")

        fixture.manager.textSelectionNavigation = NSTextSelectionNavigation(dataSource: fixture.manager)
        let after = try #require(edges(
            click(at: point, on: fixture.manager.textSelectionNavigation, in: fixture).first,
            in: fixture.manager
        ))
        #expect(after == before)
    }

    /// The seam is owned by the layout manager, which the view owns. A strong
    /// capture in either closure makes the editor immortal.
    ///
    /// Measured as a retain-count delta rather than "does it deallocate": a
    /// bare `NativeTextView` already outlives an autoreleasepool on its own
    /// (AppKit registers it in several places at init), so a `weak` reference
    /// going nil proves nothing here. Install adds no strong reference to the
    /// view other than whatever the two closures capture, so the delta IS the
    /// capture — and the control below shows the instrument can see one.
    @Test func theInstalledSeamDoesNotRetainTheTextView() throws {
        _ = NSApplication.shared
        let weakly = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let beforeWeak = CFGetRetainCount(weakly)
        weakly.installLiveTableNavigationIfNeeded()
        #expect(CFGetRetainCount(weakly) == beforeWeak)

        let strongly = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let manager = try #require(strongly.textLayoutManager)
        let beforeStrong = CFGetRetainCount(strongly)
        manager.textSelectionNavigation = LiveTableSelectionNavigation(
            dataSource: manager,
            seam: LiveTableGeometrySeam(
                hit: { strongly.liveTableHit(at: $0) },
                caretRect: { strongly.liveTableCaretRect(forOffset: $0) }
            )
        )
        #expect(CFGetRetainCount(strongly) > beforeStrong,
                "control: a strong capture must be visible, or the check above is vacuous")
    }

    // MARK: - The probe

#if DEBUG
    /// The probe is the kill criterion's instrument, so it gets its own test:
    /// one line per distinct call, repeats dropped.
    @Test func probeRecordsEachDistinctCallOnce() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        let navigation = LiveTableSelectionNavigation(
            dataSource: manager, seam: toyGrid(frame: frame, firstOffset: 30)
        )

        let wasEnabled = LiveTableNavProbe.isEnabled
        LiveTableNavProbe.isEnabled = true
        LiveTableNavProbe.reset()
        defer {
            LiveTableNavProbe.isEnabled = wasEnabled
            LiveTableNavProbe.reset()
        }

        // Same click three times: one recorded line.
        for _ in 0..<3 {
            _ = navigation.textSelections(
                interactingAt: CGPoint(x: 35, y: 25), inContainerAt: manager.documentRange.location,
                anchors: [], modifiers: [], selecting: false, bounds: tv.bounds
            )
        }
        _ = navigation.destinationSelection(
            for: caret(at: 32, in: manager), direction: .down,
            destination: .character, extending: false, confined: false
        )
        _ = navigation.textSelection(for: .word, enclosing: CGPoint(x: 35, y: 25),
                                     inContainerAt: manager.documentRange.location)
        navigation.flushLayoutCache()

        let seen = LiveTableNavProbe.seen
        #expect(seen.filter { $0.hasPrefix(LiveTableNavProbe.Label.interact) }.count == 1)
        #expect(seen.contains("\(LiveTableNavProbe.Label.interact) click →live"))
        #expect(seen.contains("\(LiveTableNavProbe.Label.destination) down →live"))
        #expect(seen.contains("\(LiveTableNavProbe.Label.granularityAtPoint) hit →live"))
        #expect(seen.contains("\(LiveTableNavProbe.Label.flushLayoutCache) →super"))
    }

    /// Falling through to `super` is recorded too — otherwise "AppKit never
    /// called us" and "our geometry declined" read the same in the console.
    @Test func probeSeparatesLiveAnswersFromFallThrough() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let navigation = LiveTableSelectionNavigation(dataSource: manager)   // disconnected

        let wasEnabled = LiveTableNavProbe.isEnabled
        LiveTableNavProbe.isEnabled = true
        LiveTableNavProbe.reset()
        defer {
            LiveTableNavProbe.isEnabled = wasEnabled
            LiveTableNavProbe.reset()
        }

        _ = navigation.textSelections(
            interactingAt: CGPoint(x: 20, y: 6), inContainerAt: manager.documentRange.location,
            anchors: [], modifiers: [], selecting: false, bounds: tv.bounds
        )
        #expect(LiveTableNavProbe.seen == ["\(LiveTableNavProbe.Label.interact) outside →super"])
    }

    /// The install prints its own line. Without it, "AppKit ignores a replaced
    /// navigation object" — the kill criterion — and "we were never installed"
    /// are the same empty console.
    @Test func probeRecordsTheInstallAndTheSurvivalCheck() throws {
        let tv = makeTextView()
        let wasEnabled = LiveTableNavProbe.isEnabled
        LiveTableNavProbe.isEnabled = true
        LiveTableNavProbe.reset()
        defer {
            LiveTableNavProbe.isEnabled = wasEnabled
            LiveTableNavProbe.reset()
        }

        tv.installLiveTableNavigationIfNeeded()
        #expect(LiveTableNavProbe.seen == [LiveTableNavProbe.Label.installed])

        tv.probeLiveTableNavigationSurvival()
        #expect(LiveTableNavProbe.seen.contains(LiveTableNavProbe.Label.survives))
        #expect(!LiveTableNavProbe.seen.contains(LiveTableNavProbe.Label.replaced))

        tv.textLayoutManager?.textSelectionNavigation =
            NSTextSelectionNavigation(dataSource: tv.textLayoutManager!)
        tv.probeLiveTableNavigationSurvival()
        #expect(LiveTableNavProbe.seen.contains(LiveTableNavProbe.Label.replaced))
    }

    @Test func probeStaysSilentWhenDisabled() throws {
        let tv = makeTextView()
        let manager = try #require(tv.textLayoutManager)
        let navigation = LiveTableSelectionNavigation(dataSource: manager)

        let wasEnabled = LiveTableNavProbe.isEnabled
        LiveTableNavProbe.isEnabled = false
        LiveTableNavProbe.reset()
        defer { LiveTableNavProbe.isEnabled = wasEnabled }

        _ = navigation.textSelections(
            interactingAt: CGPoint(x: 20, y: 6), inContainerAt: manager.documentRange.location,
            anchors: [], modifiers: [], selecting: false, bounds: tv.bounds
        )
        #expect(LiveTableNavProbe.seen.isEmpty)
    }
#endif
}
