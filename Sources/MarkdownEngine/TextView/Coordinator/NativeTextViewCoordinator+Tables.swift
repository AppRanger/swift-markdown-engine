//
//  NativeTextViewCoordinator+Tables.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Publishes where the rendered tables are so the host can overlay its own
//  row/column affordances. Structural twin of `+CodeBlocks.swift`, with three
//  deliberate differences:
//
//  1. It finds tables by scanning the `.tableAnchor` stamp rather than walking
//     tokens. The stamp only exists on a table that actually rendered — inactive
//     and in scope — so the caret-inside case needs no separate filter.
//  2. The scan is bounded to the viewport, so cost follows what is on screen,
//     not the document (a 533-table file is a measured workload here).
//  3. It never overwrites x/width with the container column the way the
//     code-block producer does: a table's box is its own, narrower than the
//     column and, in breakout mode, starting left of it.
//

import AppKit

extension NativeTextViewCoordinator {

    func updateTableGeometry(textView: NSTextView, parsed: ParsedDocument? = nil) {
        // Two of Nodes' three hosts do not want this; a nil hook pays nothing.
        guard let onTableGeometryChange else { return }
        guard let storage = textView.textStorage,
              let textContainer = textView.textContainer else {
            onTableGeometryChange([])
            return
        }

        let scrollOffset = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero

        // Identical inputs → identical geometry. The delegate path calls this
        // twice per keystroke and on every caret move. The key must include the
        // FULL active-token set: moving the caret into a standalone block swaps
        // it between picture and raw source, which moves every table below it
        // while version, scroll and width all stay put. Calls without `parsed`
        // (scroll, resize, document switch) always recompute.
        if let parsed {
            let key = (parsed.version, scrollOffset.y, textContainer.containerSize.width,
                       activeTokenIndices)
            if let last = lastTableGeoKey, last == key { return }
            lastTableGeoKey = key
        } else {
            lastTableGeoKey = nil
        }

        // One-shot full-document layout per document, shared with the code-block
        // producer — stale fragments would report wrong Y.
        if !didEnsureLayoutForCurrentDocument, let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            didEnsureLayoutForCurrentDocument = true
        }

        let scanRange = viewportCharacterRange(in: textView)
            ?? NSRange(location: 0, length: storage.length)
        guard scanRange.length > 0, NSMaxRange(scanRange) <= storage.length else {
            onTableGeometryChange([])
            return
        }

        let native = textView as? NativeTextView
        let scrollerStrip = MarkdownTextLayoutFragment.scrollableBlockScrollerStrip
        var results: [TableBlockGeometry] = []

        storage.enumerateAttribute(.tableAnchor, in: scanRange, options: []) { value, attrRange, _ in
            guard let anchor = value as? TableAnchor else { return }
            // Stale for one async hop after a document swap — the queued update
            // still holds the outgoing document's storage.
            guard NSMaxRange(anchor.sourceRange) <= storage.length else { return }

            let isScrollable = storage.attribute(
                .scrollableBlockNaturalWidth, at: attrRange.location, effectiveRange: nil
            ) != nil

            let box: CGRect
            if isScrollable {
                // A wide table's pixels live in a sibling scroll view, not in the
                // text. Ask AppKit where that view is instead of reconstructing
                // it from the anchor plus a scroll offset.
                guard let overlay = native?.wideTableOverlays[anchor.sourceID],
                      let rect = overlayRect(for: overlay, in: textView, scrollOffset: scrollOffset)
                else { return }
                box = CGRect(x: rect.minX, y: rect.minY,
                             width: rect.width,
                             height: max(0, rect.height - scrollerStrip))
            } else {
                let anchorRange = NSRange(location: attrRange.location, length: 1)
                guard let origin = textView.viewRect(forCharacterRange: anchorRange, using: layoutBridge)
                else { return }
                // Size comes from the measured grid, never from the segment: the
                // anchor char is kerned to the table's full advance and its
                // reported box is not the picture.
                box = CGRect(origin: origin.origin, size: anchor.render.geometry.totalSize)
            }

            results.append(TableBlockGeometry(
                id: anchor.sourceID,
                sourceRange: anchor.sourceRange,
                rect: box,
                gapBelow: anchor.gapBelow,
                isScrollable: isScrollable,
                bottomChromeHeight: isScrollable ? scrollerStrip : 0
            ))
        }

        onTableGeometryChange(results)
    }

    /// Character range currently laid out in the viewport, so the scan is bounded
    /// by what is on screen rather than by document length.
    private func viewportCharacterRange(in textView: NSTextView) -> NSRange? {
        guard let tlm = textView.textLayoutManager,
              let viewport = tlm.textViewportLayoutController.viewportRange else { return nil }
        let start = tlm.offset(from: tlm.documentRange.location, to: viewport.location)
        let length = tlm.offset(from: viewport.location, to: viewport.endLocation)
        return NSRange(location: start, length: length)
    }

    /// A wide-table overlay's frame in the same space `viewRect` reports — its
    /// host converted into the document view, then the scroll offset removed.
    private func overlayRect(
        for overlay: WideTableOverlay,
        in textView: NSTextView,
        scrollOffset: CGPoint
    ) -> CGRect? {
        guard let host = overlay.superview else { return nil }
        var rect = overlay.frame
        if let doc = textView.enclosingScrollView?.documentView, host !== doc {
            rect = host.convert(rect, to: doc)
        }
        rect.origin.x -= scrollOffset.x
        rect.origin.y -= scrollOffset.y
        return rect
    }
}
