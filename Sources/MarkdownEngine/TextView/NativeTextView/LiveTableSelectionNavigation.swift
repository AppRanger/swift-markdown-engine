//
//  LiveTableSelectionNavigation.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Clicks, drags and arrow keys inside a WRAPPING live table, answered from our
//  own grid geometry instead of TextKit's.
//
//  Why this exists: a live table whose cells wrap keeps each source row as ONE
//  clipped line of invisible text (the pipes stay in storage — the displayed
//  string is byte-identical to the markdown or find/copy/undo break), and the
//  layout fragment draws the wrapped cells itself. So the glyphs the user aims
//  at are nowhere near where TextKit thinks the characters are, and every
//  point↔offset answer AppKit derives from its own line fragments is wrong
//  inside a table.
//
//  `NSTextLayoutManager.textSelectionNavigation` is public and read/write
//  (`init(dataSource:)`), and NSTextView is documented to route single click,
//  drag, double/triple click, shift-click and the arrow keys through it. That
//  makes hand-managed selection possible with no private API — but it has only
//  been verified headless with a faked key window, so whether AppKit really
//  consults a REPLACED navigation object under a real first responder is the
//  project's kill criterion. `LiveTableNavProbe` (below, `MD_NAV_PROBE=1`)
//  exists to answer exactly that in one run of the real app.
//
//  INSTALLED at the bottom of this file (`installLiveTableNavigationIfNeeded`),
//  from the coordinator's view assignment and both restyle paths.
//
//  Answering the kill criterion needs no geometry: run the app with
//  `MD_NAV_PROBE=1` and click and arrow around. The install prints one line by
//  itself, and each override prints one more the first time AppKit routes that
//  input through the replaced object. `installed` with nothing after it means
//  AppKit never consults a replaced navigation object and this whole approach
//  is dead; `seam REPLACED by AppKit` means it consults one but not ours.
//
//  Outside a live table every override forwards to `super` untouched. That is
//  non-negotiable: this object sits in the path of every click and every arrow
//  key in the whole editor.
//

import AppKit

// MARK: - The seam

/// Where a point inside a live table lands, in document terms.
///
/// Two fields, both load-bearing — an earlier draft also carried the cell's
/// frame, the table's range and the line height, and navigation used none of
/// them. Anything the seam is asked for is work the renderer has to do on every
/// mouse-dragged event, so the struct stays at what is actually read.
struct LiveTableHit: Equatable {
    /// Document offset (UTF-16, storage coordinates) the point maps to.
    let offset: Int

    /// The cell's TEXT range in the document, trimmed exactly the way
    /// ``TableCells/rows(in:tableRange:)`` trims it — so a caret at
    /// `cellRange.location` sits on the character the grid draws first.
    ///
    /// Used to keep a double/triple click inside the cell: expanded by
    /// AppKit's own word/paragraph rules, a click near a cell edge would
    /// otherwise reach across the invisible `|` run and highlight characters
    /// that are not drawn anywhere near the selection.
    let cellRange: NSRange
}

/// The two questions navigation asks the live-table renderer, as closures.
///
/// A closure pair rather than a `weak var textView: NativeTextView?`, for three
/// reasons. The navigation object is owned by the layout manager, which is
/// owned by the text view, so a back-reference is a retain cycle waiting to be
/// got wrong. Tests can install a three-line fake grid and exercise every
/// branch without standing up a text view, a window or a styler. And the seam
/// stays a contract of two functions instead of an open door onto the whole
/// view — this file must never reach into `MarkdownStyler` or the fragment.
///
/// **Whoever installs this must capture the view weakly.** A closure that
/// retains the text view re-creates the cycle the closures were chosen to
/// avoid.
///
/// ## What the other side has to supply
///
/// `hit(point)` — `point` is in the coordinate space of the text container
/// (flipped, y down: the space AppKit hands
/// `textSelections(interactingAt:inContainerAt:…)`). Return `nil` unless the
/// point is inside a table that is currently in LIVE form; a table drawn as its
/// cached bitmap must return `nil`, because a click on the image is ordinary
/// caret placement around the anchor character and stock behaviour is already
/// right there. Inside a live table, CLAMP rather than refuse: a point on a
/// border, in the cell padding or past the last row still belongs to the
/// nearest cell. Returning `nil` there sends the click to `super`, which
/// answers from the invisible one-line row and drops the caret somewhere
/// unrelated. Expected implementation: find the `TableAnchor` whose drawn box
/// contains the point, subtract its origin, `TableGeometry.cell(at:)`, then
/// `LiveTableCellLayout.offset(at:alignment:)` with the point made cell-local
/// against `cellContentRect`; `cellRange` is that cell's entry in
/// `TableCells.rows(in:tableRange:)`, in document coordinates.
///
/// `caretRect(offset)` — the inverse, and `nil` for any offset that is not
/// inside a live cell's text (including the hidden pipe/padding runs between
/// cells). Container coordinates again; the height must be the cell's line
/// height, because vertical arrow keys step by it. Expected implementation:
/// `LiveTableCellLayout.caretRect(forOffset:alignment:)` plus the cell's
/// content origin.
///
/// Both are called per mouse-dragged event, so they must be cheap, and both
/// must be re-derived after a restyle — the seam is a `var` on the navigation
/// object precisely so it can be swapped when the geometry is rebuilt.
struct LiveTableGeometrySeam {
    /// Container-space point → the live cell it lands in.
    var hit: (CGPoint) -> LiveTableHit?

    /// Document offset → its caret rect in container space.
    var caretRect: (Int) -> CGRect?

    /// A pointer interaction this seam could NOT answer, with its container
    /// point. A table only draws its grid while the caret is inside it, so the
    /// click that first enters a table always arrives before there is any grid
    /// to hit-test against — the renderer keeps the point and re-asks once the
    /// table is live.
    var noteUnresolved: (CGPoint) -> Void = { _ in }

    /// The default: no live tables anywhere, so every override forwards to
    /// `super` and the editor behaves exactly as it does today. This is what
    /// makes the class safe to construct before the geometry side exists.
    static let disconnected = LiveTableGeometrySeam(
        hit: { _ in nil }, caretRect: { _ in nil }, noteUnresolved: { _ in }
    )
}

// MARK: - The probe

/// Records which navigation overrides AppKit actually calls.
///
/// The whole approach rests on NSTextView routing input through a REPLACED
/// `textSelectionNavigation`, which no amount of headless testing can prove —
/// a fake key window is not a first responder. So: run the real app with
/// `MD_NAV_PROBE=1`, click and arrow around a table, and read the console.
///
/// One line per DISTINCT label, ever. A drag fires the interaction method
/// dozens of times a second; without the dedupe the console is unreadable and
/// the app stutters on `print`.
enum LiveTableNavProbe {
    /// ObjC selector names, so a console line names the method you'd grep the
    /// AppKit header for.
    enum Label {
        static let interact = "textSelectionsInteractingAtPoint:"
        static let destination = "destinationSelectionForTextSelection:"
        static let granularityAtPoint = "textSelectionForSelectionGranularity:enclosingPoint:"
        static let granularityEnclosing = "textSelectionForSelectionGranularity:enclosingTextSelection:"
        static let resolvedInsertion = "resolvedInsertionLocationForTextSelection:"
        static let deletionRanges = "deletionRangesForTextSelection:"
        static let flushLayoutCache = "flushLayoutCache"

        /// Not an override — printed by `installLiveTableNavigationIfNeeded`.
        /// Without it, "AppKit ignores a replaced navigation object" and "we
        /// never got installed" both read as an empty console.
        static let installed = "installed"
        /// Printed when the layout manager is found holding something other
        /// than our object, which is the third possible answer.
        static let replaced = "seam REPLACED by AppKit"
        static let survives = "seam still installed"
        /// Printed the first time the caret is placed from live-table geometry.
        static let caret = "caret←liveTable"
    }

#if DEBUG
    /// `var`, not `let`, so tests can turn it on without an env var.
    static var isEnabled = ProcessInfo.processInfo.environment["MD_NAV_PROBE"] == "1"
#else
    static let isEnabled = false
#endif

    /// Distinct labels seen, in the order they first arrived. Insertion-ordered
    /// rather than a `Set` because the ORDER is half the finding: whether the
    /// interaction method precedes the destination one tells you whether a
    /// click or the arrow keys reached us first.
    private(set) static var seen: [String] = []

    /// Every call site is main-thread (AppKit input handling), same as
    /// ``PerfTrace``.
    static func record(_ label: String, _ detail: String = "", handled: Bool) {
        // Checked here and not only inside `note`: this runs on every
        // mouse-dragged event, and building the line is an allocation a shipped
        // build must not pay.
        guard isEnabled else { return }
        var line = label
        if !detail.isEmpty { line += " " + detail }
        note(line + (handled ? " →live" : " →super"))
    }

    /// One line, once, for anything that is not an override call — the install
    /// itself and the survival check.
    static func note(_ line: String) {
        guard isEnabled, !seen.contains(line) else { return }
        seen.append(line)
        print("🧭 NAV \(line)")
    }

    static func reset() { seen.removeAll() }
}

// MARK: - Navigation

/// `NSTextSelectionNavigation` that answers from live-table geometry inside a
/// table and forwards everything else to `super`.
final class LiveTableSelectionNavigation: NSTextSelectionNavigation {
    /// Swapped whenever the grid is re-measured; ``LiveTableGeometrySeam/disconnected``
    /// until someone wires it, which is what keeps this class inert.
    var seam: LiveTableGeometrySeam

    /// Sticky x for vertical arrows, in container coordinates.
    ///
    /// AppKit's own sticky column is `NSTextSelection.anchorPositionOffset`,
    /// an offset from the start of a LINE FRAGMENT — useless here, because the
    /// fragment a live row occupies is one clipped invisible line and the
    /// drawn text is not inside it. So we keep our own, cleared by any
    /// navigation that isn't a vertical step.
    private var stickyX: CGFloat?

    override init(dataSource: any NSTextSelectionDataSource) {
        self.seam = .disconnected
        super.init(dataSource: dataSource)
    }

    convenience init(dataSource: any NSTextSelectionDataSource, seam: LiveTableGeometrySeam) {
        self.init(dataSource: dataSource)
        self.seam = seam
    }

    // MARK: Click, drag, shift-click

    override func textSelections(
        interactingAt point: CGPoint,
        inContainerAt containerLocation: any NSTextLocation,
        anchors: [NSTextSelection],
        modifiers: NSTextSelectionNavigation.Modifier,
        selecting: Bool,
        bounds: CGRect
    ) -> [NSTextSelection] {
        // Any pointer interaction ends a run of vertical arrows, including one
        // that lands outside a table.
        stickyX = nil

        func fallback(_ note: String) -> [NSTextSelection] {
            LiveTableNavProbe.record(LiveTableNavProbe.Label.interact, note, handled: false)
            seam.noteUnresolved(point)
            return super.textSelections(
                interactingAt: point, inContainerAt: containerLocation,
                anchors: anchors, modifiers: modifiers, selecting: selecting, bounds: bounds
            )
        }

        // A rectangular (option-drag) or multi-range selection has no meaning in
        // a grid whose columns are drawn, not laid out. Hand it back whole.
        guard modifiers.isDisjoint(with: [.visual, .multiple]) else { return fallback("visual") }

        // The point is relative to the container at `containerLocation`, and the
        // seam measures against the one container the editor has. A foreign
        // container would silently shift every point, so refuse it — and say so,
        // because "live tables do nothing" is otherwise indistinguishable from
        // "AppKit never called us".
        guard isPrimaryContainer(containerLocation) else { return fallback("othercontainer") }

        guard let hit = seam.hit(point) else { return fallback("outside") }

        let extending = modifiers.contains(.extend) || (selecting && !anchors.isEmpty)
        let mode = extending ? (selecting ? "drag" : "shift") : "click"

        if extending, let pivot = anchorOffset(from: anchors, toward: hit.offset),
           let selection = selection(from: pivot, to: hit.offset,
                                     affinity: hit.offset >= pivot ? .downstream : .upstream) {
            LiveTableNavProbe.record(LiveTableNavProbe.Label.interact, mode, handled: true)
            return [selection]
        }
        guard let caret = selection(caretAt: hit.offset) else { return fallback("nolocation") }
        LiveTableNavProbe.record(LiveTableNavProbe.Label.interact, mode, handled: true)
        return [caret]
    }

    // MARK: Double / triple click

    override func textSelection(
        for granularity: NSTextSelection.Granularity,
        enclosing point: CGPoint,
        inContainerAt location: any NSTextLocation
    ) -> NSTextSelection? {
        func fallback(_ note: String) -> NSTextSelection? {
            LiveTableNavProbe.record(LiveTableNavProbe.Label.granularityAtPoint, note, handled: false)
            return super.textSelection(for: granularity, enclosing: point, inContainerAt: location)
        }
        guard isPrimaryContainer(location) else { return fallback("othercontainer") }
        guard let hit = seam.hit(point) else { return fallback("outside") }
        guard let caret = selection(caretAt: hit.offset) else { return fallback("nolocation") }

        // Only the point→offset half is ours. Word and paragraph boundaries are
        // a property of the STRING, which the live form leaves alone, so
        // expanding stays AppKit's job — reimplementing UAX-29 to double-click a
        // table cell would be its own bug farm.
        //
        // Clamped to the cell, though: `.paragraph` (triple click) would
        // otherwise take the whole source ROW, pipes and padding included, and
        // draw a highlight over characters that are not rendered where the
        // selection appears. Clamping makes triple click select the cell, which
        // is what a grid should do anyway.
        let expanded = super.textSelection(for: granularity, enclosing: caret)
        LiveTableNavProbe.record(LiveTableNavProbe.Label.granularityAtPoint, "hit", handled: true)
        return clamp(expanded, to: hit.cellRange, granularity: granularity) ?? caret
    }

    override func textSelection(
        for granularity: NSTextSelection.Granularity,
        enclosing textSelection: NSTextSelection
    ) -> NSTextSelection {
        // Purely logical — no geometry involved, so there is nothing to correct.
        LiveTableNavProbe.record(LiveTableNavProbe.Label.granularityEnclosing, "", handled: false)
        return super.textSelection(for: granularity, enclosing: textSelection)
    }

    // MARK: Arrow keys

    override func destinationSelection(
        for textSelection: NSTextSelection,
        direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination,
        extending: Bool,
        confined: Bool
    ) -> NSTextSelection? {
        func fallback(_ note: String) -> NSTextSelection? {
            LiveTableNavProbe.record(LiveTableNavProbe.Label.destination, note, handled: false)
            return super.destinationSelection(
                for: textSelection, direction: direction,
                destination: destination, extending: extending, confined: confined
            )
        }

        // Horizontal and logical movement is already right: the cell text is
        // real text in document order, so ←/→ walk it correctly. (They do step
        // through the hidden pipe/padding runs between cells, where the caret
        // appears to stall for a few presses. Skipping those needs cell-boundary
        // policy that belongs with whoever owns the styler, not here.)
        guard direction == .up || direction == .down else {
            stickyX = nil
            return fallback("horizontal")
        }
        // ⌥↑/⌘↑ and friends ask for paragraph/document destinations, which mean
        // the same thing in a table as anywhere else.
        guard destination == .character, !confined else { return fallback("nonline") }

        guard let current = movingEdgeOffset(of: textSelection, direction: direction),
              let rect = seam.caretRect(current) else { return fallback("outside") }

        let x = stickyX ?? rect.minX
        let step = max(1, rect.height)
        let probeY = direction == .up ? rect.midY - step : rect.midY + step

        // No hit means the step left the table — off the top of the header or
        // past the last row. `super` then moves the caret out of the table,
        // which is the behaviour we want and the reason this is a fallback and
        // not a clamp.
        guard let hit = seam.hit(CGPoint(x: x, y: probeY)) else {
            stickyX = nil
            return fallback("exit")
        }
        stickyX = x

        if extending, let pivot = oppositeEdgeOffset(of: textSelection, direction: direction),
           let selection = selection(from: pivot, to: hit.offset,
                                     affinity: hit.offset >= pivot ? .downstream : .upstream) {
            LiveTableNavProbe.record(LiveTableNavProbe.Label.destination, "extend", handled: true)
            return selection
        }
        guard let caret = selection(caretAt: hit.offset) else { return fallback("nolocation") }
        LiveTableNavProbe.record(LiveTableNavProbe.Label.destination, direction == .up ? "up" : "down", handled: true)
        return caret
    }

    // MARK: Pass-through (probed, so the console shows the full routed surface)

    override func resolvedInsertionLocation(
        for textSelection: NSTextSelection,
        writingDirection: NSTextSelectionNavigation.WritingDirection
    ) -> (any NSTextLocation)? {
        LiveTableNavProbe.record(LiveTableNavProbe.Label.resolvedInsertion, "", handled: false)
        return super.resolvedInsertionLocation(for: textSelection, writingDirection: writingDirection)
    }

    override func deletionRanges(
        for textSelection: NSTextSelection,
        direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination,
        allowsDecomposition: Bool
    ) -> [NSTextRange] {
        // A delete is an edit, and the next ↑ should start from the new caret,
        // not the column the user was arrowing down.
        stickyX = nil
        LiveTableNavProbe.record(LiveTableNavProbe.Label.deletionRanges, "", handled: false)
        return super.deletionRanges(
            for: textSelection, direction: direction,
            destination: destination, allowsDecomposition: allowsDecomposition
        )
    }

    override func flushLayoutCache() {
        // Nothing of ours to drop: every answer above is computed on demand from
        // the seam. The seam's OWNER is what has to invalidate on edit — if a
        // stale closure survives a restyle, clicks land on the previous layout.
        stickyX = nil
        LiveTableNavProbe.record(LiveTableNavProbe.Label.flushLayoutCache, "", handled: false)
        super.flushLayoutCache()
    }

    // MARK: - Offsets and locations

    /// True when `location` is the start of the document, i.e. the single text
    /// container the editor uses.
    /// Whether `location` names a place in this editor's document.
    ///
    /// NOT "is it the document's first location": AppKit passes the location the
    /// container starts at, and under TextKit 2's viewport layout that walks
    /// forward as the document scrolls. Requiring the document start therefore
    /// refused every point below the first viewport — measured: clicks in a
    /// table near the top resolved live, the same table's last row fell through
    /// to `super`. Worse than doing nothing: the anchor then came from AppKit's
    /// one-line row while the drag came from us, and the resulting selection
    /// spanned the whole row, so the next keystroke replaced it.
    ///
    /// The editor has exactly one text container, so any location the data
    /// source can measure is ours.
    private func isPrimaryContainer(_ location: any NSTextLocation) -> Bool {
        guard let source = textSelectionDataSource else { return false }
        guard source.documentRange.location.compare(location) != .orderedDescending,
              source.documentRange.endLocation.compare(location) != .orderedAscending
        else { return false }
        return offset(of: location) != nil
    }

    private func location(atOffset offset: Int) -> (any NSTextLocation)? {
        guard let source = textSelectionDataSource, offset >= 0 else { return nil }
        return source.location(source.documentRange.location, offsetBy: offset)
    }

    private func offset(of location: any NSTextLocation) -> Int? {
        guard let source = textSelectionDataSource else { return nil }
        let value = source.offset(from: source.documentRange.location, to: location)
        return value == NSNotFound ? nil : value
    }

    private func selection(caretAt offset: Int) -> NSTextSelection? {
        guard let location = location(atOffset: offset) else { return nil }
        return NSTextSelection(location, affinity: .downstream)
    }

    private func selection(
        from: Int, to: Int,
        affinity: NSTextSelection.Affinity,
        granularity: NSTextSelection.Granularity = .character
    ) -> NSTextSelection? {
        guard let start = location(atOffset: min(from, to)),
              let end = location(atOffset: max(from, to)),
              let range = NSTextRange(location: start, end: end) else { return nil }
        return NSTextSelection(range: range, affinity: affinity, granularity: granularity)
    }

    /// Trim a selection to `range`, keeping the requested granularity — AppKit
    /// documents that the selection it hands back from a granularity query
    /// carries that granularity, and later extend-by-granularity reads it.
    /// `nil` when the two do not overlap at all.
    private func clamp(
        _ selection: NSTextSelection, to range: NSRange, granularity: NSTextSelection.Granularity
    ) -> NSTextSelection? {
        guard let first = selection.textRanges.first,
              let last = selection.textRanges.last,
              let start = offset(of: first.location),
              let end = offset(of: last.endLocation) else { return nil }
        let lower = max(start, range.location)
        let upper = min(end, NSMaxRange(range))
        guard upper >= lower else { return nil }
        return self.selection(from: lower, to: upper, affinity: .downstream, granularity: granularity)
    }

    /// The edge of the anchor selection to KEEP while dragging: the one farther
    /// from the new point. That is what makes a shift-click grow the selection
    /// away from where it already reaches, instead of collapsing it.
    private func anchorOffset(from anchors: [NSTextSelection], toward offset: Int) -> Int? {
        guard let anchor = anchors.first,
              let first = anchor.textRanges.first,
              let last = anchor.textRanges.last,
              let start = self.offset(of: first.location),
              let end = self.offset(of: last.endLocation) else { return nil }
        return abs(offset - start) >= abs(offset - end) ? start : end
    }

    /// The edge an arrow key moves. `NSTextSelection` does not say which end is
    /// anchored, so direction decides — correct whenever the user keeps
    /// shift-arrowing one way, which is the case worth getting right.
    private func movingEdgeOffset(
        of selection: NSTextSelection, direction: NSTextSelectionNavigation.Direction
    ) -> Int? {
        guard let first = selection.textRanges.first,
              let last = selection.textRanges.last else { return nil }
        return direction == .up ? offset(of: first.location) : offset(of: last.endLocation)
    }

    /// The edge an arrow key leaves behind while extending.
    private func oppositeEdgeOffset(
        of selection: NSTextSelection, direction: NSTextSelectionNavigation.Direction
    ) -> Int? {
        guard let first = selection.textRanges.first,
              let last = selection.textRanges.last else { return nil }
        return direction == .up ? offset(of: last.endLocation) : offset(of: first.location)
    }
}

// MARK: - Installation

extension NativeTextView {
    /// Put the live-table navigation in front of AppKit's own, idempotently.
    ///
    /// Called from the coordinator's `textView` assignment (which is what
    /// `makeNSView` and every remount go through) and from both restyle paths,
    /// so a document switch or a re-style cannot leave the editor navigating
    /// against the invisible one-line rows. It costs one `is` check when it is
    /// already there.
    ///
    /// The seam captures the view **weakly**. The navigation object is retained
    /// by the layout manager, the layout manager by this view — a strong
    /// capture would close that loop and the editor would never deallocate.
    ///
    /// The seam is never re-derived, deliberately: both closures ask the view,
    /// which reads the CURRENT fragments and the CURRENT `.liveTableRow` stamps
    /// every call. There is no captured geometry to go stale, so a restyle has
    /// nothing to swap — it only has to make sure the object is still there.
    func installLiveTableNavigationIfNeeded() {
        guard let manager = textLayoutManager else { return }
        guard !(manager.textSelectionNavigation is LiveTableSelectionNavigation) else { return }
        let navigation = LiveTableSelectionNavigation(dataSource: manager)
        navigation.seam = LiveTableGeometrySeam(
            hit: { [weak self] point in
                guard let self, self.viewportHasLiveTableRow else { return nil }
                let hit = self.liveTableHit(at: point)
                // Answered live, so there is nothing left to re-aim.
                if hit != nil { self.pendingLiveTableClick = nil }
                return hit
            },
            caretRect: { [weak self] offset in
                guard let self, self.liveTableRowRender(atOffset: offset) != nil else { return nil }
                return self.liveTableCaretRect(forOffset: offset)
            },
            noteUnresolved: { [weak self] point in
                self?.pendingLiveTableClick = point
            }
        )
        manager.textSelectionNavigation = navigation
        LiveTableNavProbe.note(LiveTableNavProbe.Label.installed)
    }

    /// DEBUG: report whether the layout manager is still holding our object.
    ///
    /// The kill criterion has three possible answers, not two — AppKit may
    /// never consult a replaced navigation object, or it may consult one but
    /// have swapped ours out. Both look like an empty console otherwise.
    func probeLiveTableNavigationSurvival() {
        guard LiveTableNavProbe.isEnabled, let manager = textLayoutManager else { return }
        LiveTableNavProbe.note(
            manager.textSelectionNavigation is LiveTableSelectionNavigation
                ? LiveTableNavProbe.Label.survives
                : LiveTableNavProbe.Label.replaced
        )
    }

    // MARK: Cheap gates

    /// The live row stamped on the character at `offset`, or nil.
    ///
    /// One attribute read, and the gate in front of every seam answer:
    /// `liveTableHit`/`liveTableCaretRect` walk EVERY laid-out fragment in the
    /// document, and both sit on paths that run per keystroke (caret) and per
    /// mouse-dragged event (hit). Without this, a document with no table at all
    /// pays that walk on every one of them.
    func liveTableRowRender(atOffset offset: Int) -> LiveTableRowRender? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        // An offset one past the last character still belongs to the last
        // paragraph, and a cell's end offset can land there.
        let index = min(max(0, offset), storage.length - 1)
        return storage.attribute(.liveTableRow, at: index, effectiveRange: nil) as? LiveTableRowRender
    }

    /// True when any live-table row is stamped inside the laid-out viewport.
    ///
    /// The point half of the seam gets no offset to test, so it gates on the
    /// viewport instead: a click can only land on something drawn, and only the
    /// viewport is drawn. Runs over attribute runs, not fragments, and stops at
    /// the first hit.
    var viewportHasLiveTableRow: Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let range = liveTableScanRange ?? NSRange(location: 0, length: storage.length)
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        var found = false
        storage.enumerateAttribute(
            .liveTableRow, in: range, options: [.longestEffectiveRangeNotRequired]
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Character range TextKit currently has laid out, or nil when there is no
    /// viewport yet (headless, or before the first layout pass).
    private var liveTableScanRange: NSRange? {
        guard let manager = textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return nil }
        let start = manager.offset(from: manager.documentRange.location, to: viewport.location)
        let length = manager.offset(from: viewport.location, to: viewport.endLocation)
        guard start != NSNotFound, length != NSNotFound else { return nil }
        return NSRange(location: start, length: length)
    }
}
