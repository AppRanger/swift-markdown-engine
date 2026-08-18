//
//  NativeTextView+LiveTableHitTest.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  The renderer's half of the live-table navigation seam.
//
//  A live table's row is one invisible line of text whose cells are drawn by the
//  layout fragment, so TextKit's own answer to "which character is at this
//  point" is the one-line answer and is wrong. These two functions answer from
//  the drawn geometry instead, and are handed to `LiveTableSelectionNavigation`
//  as closures.
//
//  Both work in TEXT CONTAINER coordinates (flipped, y down) — the space AppKit
//  passes to `textSelections(interactingAt:inContainerAt:…)`.
//

import AppKit

extension NativeTextView {
    /// Rows currently laid out, with the container-space origin each one draws at.
    ///
    /// Scoped to the VIEWPORT, and deliberately without `.ensuresLayout`. Both
    /// callers run per mouse-dragged event and per caret update; enumerating the
    /// whole document measured 5.4 ms on a 300k note — a third of the entire
    /// per-keystroke budget — and forcing full-document layout from inside a
    /// caret update is the exact cost the large-file work exists to avoid. A
    /// click can only land on something drawn, and only the viewport is drawn.
    private func liveTableRows() -> [(render: LiveTableRowRender, origin: CGPoint)] {
        guard let tlm = textLayoutManager else { return [] }
        let viewport = tlm.textViewportLayoutController.viewportRange
        let start = viewport?.location ?? tlm.documentRange.location
        let end = viewport?.endLocation

        var result: [(LiveTableRowRender, CGPoint)] = []
        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            if let end, fragment.rangeInElement.location.compare(end) == .orderedDescending {
                return false
            }
            if let fragment = fragment as? MarkdownTextLayoutFragment,
               let render = fragment.liveTableRowRender {
                let top = fragment.textLineFragments.first?.typographicBounds.origin.y ?? 0
                // Same shift the fragment draws with, or a click would land on
                // the cell that USED to be under the pointer.
                let origin = CGPoint(
                    x: fragment.layoutFragmentFrame.origin.x - liveTableScrollX(for: render),
                    y: fragment.layoutFragmentFrame.origin.y + top
                )
                result.append((render, origin))
            }
            return true
        }
        return result
    }

    /// How far this table is scrolled right, or 0 when it fits the column.
    func liveTableScrollX(for render: LiveTableRowRender) -> CGFloat {
        guard let width = textContainer?.size.width,
              render.geometry.totalSize.width > width + 0.5 else { return 0 }
        return liveTableScrollX
    }

    /// Cell content origin, relative to the row's own top-left.
    private func cellOrigin(_ render: LiveTableRowRender, column: Int) -> CGPoint? {
        guard let left = render.geometry.contentLeft(column) else { return nil }
        return CGPoint(x: left, y: render.geometry.cellVPadding)
    }

    /// Where a point inside a live table lands, in document terms.
    ///
    /// Clamps inside a table rather than refusing: a point on a border or in the
    /// padding still belongs to the nearest cell, and returning nil there would
    /// send the click to the stock navigation, which answers from the invisible
    /// one-line row.
    func liveTableHit(at containerPoint: CGPoint) -> LiveTableHit? {
        applyPendingLiveTableScrollSeed()
        for (render, origin) in liveTableRows() {
            let box = CGRect(
                x: origin.x, y: origin.y,
                width: render.geometry.totalSize.width, height: render.rowHeight
            )
            guard box.contains(containerPoint) else { continue }
            // The delimiter row is a hairline with no text; snap to the first
            // cell of the row below it rather than answering from a 1pt band.
            guard !render.isDelimiter, !render.cells.isEmpty else { return nil }

            let local = CGPoint(x: containerPoint.x - origin.x, y: containerPoint.y - origin.y)
            let requested = render.geometry.column(at: local.x) ?? 0
            let column = min(requested, render.cells.count - 1)
            // A drawn cell the row has no source for. Answer from the last cell
            // that exists so the caret lands somewhere sane, and leave a note so
            // the gesture's tail can create the real one.
            pendingLiveTableCellCreation = requested > column
                ? (render.lineRange, render.tableRange, requested)
                : nil
            let cell = render.cells[column]
            guard let cellTopLeft = cellOrigin(render, column: column) else { return nil }
            let cellLocal = CGPoint(x: local.x - cellTopLeft.x, y: local.y - cellTopLeft.y)
            let alignment = render.geometry.alignments[column]
            let resolved = cell.resolve(at: cellLocal, alignment: alignment)
            // The click's own y already said which wrapped line was meant, so
            // record it before the offset loses that.
            liveTableCaretHint = (resolved.offset, resolved.upstream)
            return LiveTableHit(
                offset: resolved.offset,
                cellRange: NSRange(location: cell.sourceLocation, length: cell.attributed.length)
            )
        }
        return nil
    }

    /// Caret rect for a document offset inside a live cell, in container space.
    ///
    /// nil for the hidden pipe and padding runs between cells — those have no
    /// drawn position, and the caller should leave the caret where it was rather
    /// than move it somewhere arbitrary.
    func liveTableCaretRect(forOffset offset: Int) -> CGRect? {
        for (render, origin) in liveTableRows() where !render.isDelimiter {
            guard !render.cells.isEmpty else { continue }
            // The whole source line, so a caret on a hidden pipe still belongs to
            // this row — the hit test resolves such points into a cell, and the
            // two must not disagree.
            guard offset >= render.lineRange.location,
                  offset <= NSMaxRange(render.lineRange) else { continue }

            // Between two cells the offset sits on a hidden pipe or its padding,
            // which is drawn nowhere. Returning nil there let TextKit's own caret
            // stand — a full-row-height bar at the left margin — so every
            // left/right crossing of a cell edge flashed the caret across the
            // table. Snap to the nearest cell edge instead.
            var chosen: (column: Int, cell: LiveTableCellLayout, offset: Int)?
            var bestDistance = Int.max
            for (column, cell) in render.cells.enumerated() {
                // The PADDED span: a space typed at the end of a cell sits
                // outside the trimmed text, and clamping it back onto the last
                // letter left the caret standing still while the character
                // reached the file.
                let start = cell.caretRange.location
                let end = NSMaxRange(cell.caretRange)
                let clamped = min(max(offset, start), end)
                let distance = abs(offset - clamped)
                if distance < bestDistance {
                    bestDistance = distance
                    chosen = (column, cell, clamped)
                }
                if distance == 0 { break }
            }
            // Set by the click that placed this caret, or by the direction it
            // last moved in. Stale hints are ignored rather than guessed at.
            let upstream = liveTableCaretHint?.offset == offset
                && liveTableCaretHint?.upstream == true
            guard let chosen,
                  let cellTopLeft = cellOrigin(render, column: chosen.column),
                  let rect = chosen.cell.caretRect(
                      forOffset: chosen.offset,
                      alignment: render.geometry.alignments[chosen.column],
                      preferUpstream: upstream
                  ) else { return nil }
            return rect.offsetBy(
                dx: origin.x + cellTopLeft.x,
                dy: origin.y + cellTopLeft.y
            )
        }
        return nil
    }

    /// True while the caret sits inside a table showing its live grid — the
    /// condition every hand-managed branch gates on.
    var isCaretInLiveTable: Bool {
        liveTableCaretRect(forOffset: selectedRange().location) != nil
    }
}

// MARK: - Panning a live table wider than the column

extension NativeTextView {

    /// Take over the picture's scroll position, once, as soon as the table it
    /// came from has gone live.
    ///
    /// Everything that reads `liveTableScrollX` calls this first, because the
    /// handover and the click re-aim otherwise race: the re-aim ran while the
    /// offset was still 0 and resolved a click made at visible x=560 on a table
    /// scrolled 315 to the right — six columns to the left of the cell under the
    /// pointer. One owner, no ordering to get wrong.
    func applyPendingLiveTableScrollSeed() {
        let signature = liveTableSignature
        if let seed = pendingLiveTableScrollSeed {
            // Only once the grid exists: the click hands the seed over BEFORE the
            // table goes live, and until it does there is no width to clamp
            // against, so consuming it early would clamp it to zero.
            guard liveTableOverflow > 0 else { return }
            pendingLiveTableScrollSeed = nil
            lastLiveTableScrollSignature = signature
            liveTableScrollX = min(max(0, seed), liveTableOverflow)
            return
        }
        // No handover: only a DIFFERENT table starts at its beginning. Keyed on
        // the signature and never on -1, which is "no live row stamped right
        // now" — reported for a moment during every restyle, so on every
        // keystroke, and resetting there threw a scrolled table back to column 1
        // mid-typing. That is also why the signature alone cannot drive the
        // handover: re-entering the SAME table does not change it, and the
        // picture's new position was thrown away.
        guard signature != -1, signature != lastLiveTableScrollSignature else { return }
        lastLiveTableScrollSignature = signature
        liveTableScrollX = 0
    }

    /// The live table's width beyond the text column, or 0 when it fits.
    var liveTableOverflow: CGFloat {
        guard let width = textContainer?.size.width else { return 0 }
        // From the ROWS on screen, not from the row under the caret. That row is
        // unstamped for a moment during every restyle, so asking it reported no
        // overflow on a table measuring 965 against a 650 column — and the
        // scroller dutifully hid itself on every keystroke. The rows are the same
        // source the grid draws and hit-tests from, so all three now agree.
        let widest = liveTableRows().map(\.render.geometry.totalSize.width).max() ?? 0
        return max(0, widest - width)
    }

    /// Move the live table to `x` points from its left edge, clamped, and force
    /// it to redraw. Returns true when anything moved.
    ///
    /// `invalidateLayout`, not `setNeedsDisplay`: TextKit 2 caches a fragment's
    /// rendered surface, and that cache is exactly what defeated in-fragment
    /// scrolling when the picture overlay was built. Invalidating the range
    /// rebuilds the fragments, which is the only thing that reliably repaints.
    @discardableResult
    func setLiveTableScroll(_ x: CGFloat, reason: String = "?") -> Bool {
        let clamped = min(max(0, x), liveTableOverflow)
        guard abs(clamped - liveTableScrollX) > 0.01 else { return false }
        liveTableScrollX = clamped
        guard let render = liveTableRowRender(atOffset: selectedRange().location),
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let start = tcs.location(tcs.documentRange.location, offsetBy: render.tableRange.location),
              let end = tcs.location(start, offsetBy: render.tableRange.length),
              let range = NSTextRange(location: start, end: end) else { return true }
        tlm.invalidateLayout(for: range)
        return true
    }

    /// Keep the caret inside the visible slice of a scrolled live table.
    ///
    /// Typing walks the caret along a row; without this it would leave the
    /// column's edge and keep going invisibly, which is how a scrolled table
    /// loses the person editing it.
    func revealLiveTableCaret() {
        // Not while a click is still waiting to be re-aimed. Until it lands the
        // caret sits on the table's anchor — its first cell — which on a table
        // scrolled right is off screen to the LEFT, so the reveal dutifully
        // drags the view back to column 1 and undoes the scroll the click was
        // supposed to keep. The re-aim runs a turn later and puts the caret in
        // the clicked cell, which is on screen already.
        guard pendingLiveTableClick == nil else { return }
        guard liveTableOverflow > 0, let width = textContainer?.size.width,
              let rect = liveTableCaretRect(forOffset: selectedRange().location) else { return }
        let margin: CGFloat = 24   // a cell's padding, so the caret is not flush against the cut
        if rect.minX < margin {
            setLiveTableScroll(liveTableScrollX + rect.minX - margin, reason: "caret left of view")
        } else if rect.maxX > width - margin {
            setLiveTableScroll(liveTableScrollX + rect.maxX - width + margin, reason: "caret right of view")
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if scrollLiveTableHorizontally(with: event) { return }
        super.scrollWheel(with: event)
    }

    /// Horizontal wheel or trackpad over a live table that overflows pans the
    /// table rather than the document.
    func scrollLiveTableHorizontally(with event: NSEvent) -> Bool {
        guard liveTableOverflow > 0 else { return false }
        let dx = event.scrollingDeltaX
        // Vertical intent wins: a two-finger scroll is never purely one axis,
        // and swallowing it would trap the document under the table.
        guard abs(dx) > abs(event.scrollingDeltaY) else { return false }
        setLiveTableScroll(liveTableScrollX - dx, reason: "wheel")
        return true
    }
}

