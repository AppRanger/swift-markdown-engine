//
//  NativeTextView+CaretWorkarounds.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Caret-indicator workarounds: block-image hide/resize + trailing-`\n` Y-snap
//  (FB22524198) + live-table placement.
//

import AppKit

extension NativeTextView {
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        applyBlockImageCaretPolicy()
        // Last, so it wins over the two policies above when it applies at all.
        applyLiveTableCaretPolicy()
        probeLiveTableNavigationSurvival()
        DispatchQueue.main.async { [weak self] in
            self?.createPendingLiveTableCell()
            self?.fixPhantomTrailingCaret()
            self?.applyLiveTableCaretPolicy()
        }
    }

    /// Create the cell the user clicked, when the row's source has none.
    ///
    /// A row with fewer cells than the header draws the rest empty, so the grid
    /// offers a cell that does not exist in the text. Rather than let the click
    /// fall into a neighbouring cell, add the missing `|`s and put the caret in
    /// the new one — a plain insertion, so wiki-link ids and undo survive it.
    private func createPendingLiveTableCell() {
        guard let pending = pendingLiveTableCellCreation else { return }
        pendingLiveTableCellCreation = nil
        guard isEditable, selectedRange().length == 0, let storage = textStorage else { return }
        // Counted BEFORE the edit: the caret offsets are indexed by how many
        // cells the row is gaining, and after the insertion the recorded line
        // range no longer covers the row.
        let present = MarkdownTableEditor.cellCount(
            in: storage.string as NSString, lineRange: pending.line
        )
        guard let padded = MarkdownTableEditor.padRowInsertion(
            in: storage.string as NSString,
            tableRange: pending.table,
            lineRange: pending.line
        ) else { return }

        let range = NSRange(location: padded.insertion.location, length: 0)
        guard shouldChangeText(in: range, replacementString: padded.insertion.text) else { return }
        // Fence both sides so one Cmd+Z takes back the cell and not the typing
        // that follows it.
        breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: padded.insertion.text)
        didChangeText()
        breakUndoCoalescing()

        let index = min(max(0, pending.column - present), padded.caretOffsets.count - 1)
        setSelectedRange(NSRange(location: padded.caretOffsets[index], length: 0))
    }

    /// Re-aim the click that turned a table live.
    ///
    /// It was resolved while the table was still a bitmap, so it landed on the
    /// anchor character — the table's first cell — regardless of the cell aimed
    /// at. Now that the grid exists, the same point resolves properly. Only ever
    /// applies to a plain caret already inside the live table, so a drag,
    /// a selection, or a click that never entered a table is left alone.
    private func resolvePendingLiveTableClick() {
        guard let point = pendingLiveTableClick else { return }
        let selection = selectedRange()
        guard selection.length == 0,
              liveTableCaretRect(forOffset: selection.location) != nil,
              let hit = liveTableHit(at: point)
        else { return }
        pendingLiveTableClick = nil
        guard hit.offset != selection.location else { return }
        setSelectedRange(NSRange(location: hit.offset, length: 0))
    }

    /// Put the caret on the cell the user is actually typing in.
    ///
    /// A live table's row is one clipped, size-hidden line of source, so
    /// TextKit's caret for any offset in it is a 0.1pt sliver at the row's far
    /// left — nowhere near the drawn grid. `liveTableCaretRect` answers from the
    /// same per-cell layouts the fragment draws with, which is the only place
    /// the real position exists.
    ///
    /// Re-asserted from the same three points the trailing-`\n` snap is (this
    /// method's caller, its async tail, and the indicator's own frame KVO), and
    /// through the same `isApplyingCaretShift` guard, so our own write does not
    /// re-enter as if AppKit had moved the caret.
    func applyLiveTableCaretPolicy() {
        resolvePendingLiveTableClick()
        let offset = selectedRange().location
        // Settle which side of a soft wrap this offset means, ONCE per move.
        // This method runs several times per event; recomputing the direction on
        // each would flip the answer the moment the reference caught up, and the
        // caret would jump back to the next line by itself.
        if liveTableCaretHint?.offset != offset {
            liveTableCaretHint = (offset, offset > lastLiveTableCaretOffset)
        }
        lastLiveTableCaretOffset = offset
        guard let indicator = subviews.first(where: { type(of: $0) == NSTextInsertionIndicator.self }) else {
            return
        }
        guard let target = liveTableCaretIndicatorFrame(width: max(indicator.frame.width, 1)) else {
            return
        }
        guard !target.equalTo(indicator.frame) else {
            return
        }
        isApplyingCaretShift = true
        // NSTextInsertionIndicator animates its frame, so AppKit's own answer —
        // a full-row-height bar at the row's left edge — was visibly sliding to
        // the clicked cell on every click. We are correcting a wrong position,
        // not moving the caret, so it must be instant.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            indicator.animator().frame = target
            indicator.frame = target
        }
        isApplyingCaretShift = false
        LiveTableNavProbe.note(LiveTableNavProbe.Label.caret)
    }

    /// Frame the insertion indicator should have, in TEXT-VIEW coordinates, or
    /// nil when the caret is not inside a live cell.
    ///
    /// Split out from the writer so the geometry is testable headless: without a
    /// key window there is no `NSTextInsertionIndicator` subview to move, and
    /// the conversion is the half that can be wrong.
    func liveTableCaretIndicatorFrame(width: CGFloat) -> CGRect? {
        let selection = selectedRange()
        guard selection.length == 0,
              let render = liveTableRowRender(atOffset: selection.location),
              !render.isDelimiter,
              let rect = liveTableCaretRect(forOffset: selection.location) else { return nil }
        // Container space (what the fragment lays out in) → view space (what the
        // indicator's frame is in). Same conversion `viewRect(forCharacterRange:)`
        // makes, and it self-zeroes when an embedder leaves the insets at 0.
        let containerOrigin = textContainerOrigin
        return CGRect(
            x: rect.minX + containerOrigin.x,
            y: rect.minY + containerOrigin.y,
            width: width,
            height: rect.height
        )
    }

    func applyBlockImageCaretPolicy() {
        let indicators = subviews.filter { type(of: $0) == NSTextInsertionIndicator.self }
        guard !indicators.isEmpty else { return }

        var hide = false
        var resize = false
        if let ts = textStorage {
            let sel = selectedRange()
            if sel.length != 0 || sel.location > ts.length {
                hide = true
            } else if sel.location < ts.length {
                let paraRange = (ts.string as NSString).paragraphRange(
                    for: NSRange(location: sel.location, length: 0)
                )
                ts.enumerateAttribute(.latexIsBlock, in: paraRange, options: []) { value, range, stop in
                    guard value as? Bool == true else { return }
                    if ts.attribute(.latexBlockOffsetY, at: range.location, effectiveRange: nil) != nil {
                        resize = true
                    } else {
                        hide = true
                        stop.pointee = true
                    }
                }
            }
        }

        for sub in indicators {
            if !hide && resize { resizeIndicatorToLayoutCaret(sub) }
            if sub.isHidden != hide { sub.isHidden = hide }
        }
    }

    /// After collapsed→visible, the indicator frame stays at image height; snap it to the layout manager's actual caret rect.
    func resizeIndicatorToLayoutCaret(_ indicator: NSView) {
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let docLoc = tcs.location(tcs.documentRange.location, offsetBy: selectedRange().location) else { return }
        var layoutRect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: docLoc), type: .standard, options: [.rangeNotRequired]) { _, f, _, _ in
            layoutRect = f; return false
        }
        guard let r = layoutRect, r.height > 0,
              indicator.frame.height > r.height + 1 else { return }
        isApplyingCaretShift = true
        indicator.frame = CGRect(x: indicator.frame.origin.x, y: r.origin.y,
                                 width: indicator.frame.width, height: r.height)
        isApplyingCaretShift = false
    }

    /// FB22524198: AppKit drops the trailing-`\n` caret onto the previous line's top — snap it to `lastLineMaxY + paragraphSpacing` instead. (Companion to FB15131180; this one fixes Y, the other fixes height.)
    func fixPhantomTrailingCaret() {
        if let indicator = subviews.first(where: { type(of: $0) == NSTextInsertionIndicator.self }),
           observedCaretIndicator !== indicator {
            caretIndicatorObservation?.invalidate()
            observedCaretIndicator = indicator
            caretIndicatorObservation = indicator.observe(\.frame, options: [.new]) { [weak self] _, _ in
                guard let self, !self.isApplyingCaretShift else { return }
                self.applyBlockImageCaretPolicy()
                self.fixPhantomTrailingCaret()
                self.applyLiveTableCaretPolicy()
            }
        }
        guard let ts = textStorage, let indicator = observedCaretIndicator,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else { return }
        let sel = selectedRange()
        let ns = ts.string as NSString
        guard sel.length == 0, sel.location == ns.length, ns.length > 0,
              ns.character(at: ns.length - 1) == 0x0A,
              let trailingLoc = tcs.location(tcs.documentRange.location, offsetBy: ns.length - 1) else {
            return
        }
        var desiredY: CGFloat?
        tlm.enumerateTextLayoutFragments(from: trailingLoc, options: [.ensuresLayout]) { fragment in
            // Use the LAST text line (length > 0) so multi-line wrapped paragraphs aren't pulled to the first line.
            let lastTextLine = fragment.textLineFragments.last { $0.characterRange.length > 0 }
                ?? fragment.textLineFragments.last
            guard let line = lastTextLine else { return false }
            let lineMaxY = fragment.layoutFragmentFrame.origin.y + line.typographicBounds.maxY
            let style = ts.attribute(.paragraphStyle, at: ns.length - 1, effectiveRange: nil) as? NSParagraphStyle
            // Layout-fragment Y is textContainer-relative; the indicator frame is textView-relative — add the textContainerInset offset so the snap stays correct when an embedder configures non-zero text insets.
            desiredY = lineMaxY + (style?.paragraphSpacing ?? 0) + self.textContainerInset.height
            return false
        }
        guard let desiredY, abs(indicator.frame.origin.y - desiredY) >= 0.5 else { return }
        isApplyingCaretShift = true
        indicator.frame.origin.y = desiredY
        isApplyingCaretShift = false
    }
}
