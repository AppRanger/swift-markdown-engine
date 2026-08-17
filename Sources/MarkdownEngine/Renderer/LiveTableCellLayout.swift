//
//  LiveTableCellLayout.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  One table cell, laid out on its own at its column's width.
//
//  The live table cannot ask TextKit 2 to place columns — table layout went
//  through NSTypesetter, which TextKit 2 removed, and a line fragment we build
//  ourselves is never laid out. So the row stays ONE line of invisible text in
//  the document (the pipes keep their characters, find and copy keep working)
//  and the grid is drawn by the fragment from these per-cell layouts.
//
//  Because the drawn text no longer sits where TextKit thinks it does, the
//  caret and hit-testing have to be answered from here too — hence
//  `offset(at:)` and `rect(forOffset:)` alongside `draw`.
//
//  Coordinates are cell-local: origin at the cell's TEXT top-left, y down.
//

import AppKit

struct LiveTableCellLayout {

    /// The cell's text, styled the way it is drawn.
    let attributed: NSAttributedString
    /// Document location of the cell's first character, so offsets computed
    /// here can be turned back into document indices.
    let sourceLocation: Int
    /// Width the text was wrapped at — the column's content width.
    let width: CGFloat
    /// Height of one line, pinned so measurement and drawing cannot disagree.
    let lineHeight: CGFloat
    /// Character ranges of the wrapped lines, relative to `attributed`.
    let lineRanges: [NSRange]
    /// Document range the caret may stand in — the cell's text PLUS the padding
    /// spaces on either side of it. Cells are trimmed for drawing (GFM ignores
    /// that padding), but the characters are real and typing puts the caret
    /// among them.
    /// Indices of lines that end at a `<br>` rather than at a soft wrap.
    ///
    /// At a soft wrap there are NO characters between one line and the next, so
    /// a single offset means two drawn places and only the caret's history can
    /// say which. A hard break has four real characters: the offset past them
    /// can only be the start of the next line. Without this the one keypress
    /// whose whole purpose is "go to a new line" moved the caret nowhere.
    let hardTerminated: Set<Int>
    let caretRange: NSRange
    /// Advance of one space in this cell's font, to place the caret inside the
    /// trailing padding, whose characters are not part of `attributed`.
    let spaceAdvance: CGFloat

    var lineCount: Int { max(1, lineRanges.count) }
    var height: CGFloat { CGFloat(lineCount) * lineHeight }

    // MARK: - Building

    /// Wrap `attributed` at `width`, recording where each line begins.
    ///
    /// Uses one detached TextKit 1 stack: it is the only API that reports line
    /// break positions for a standalone string, it never touches the editor's
    /// layout, and `NSAttributedString.draw` goes through the same typesetter —
    /// so the breaks measured here are the breaks that get drawn.
    /// Wrapped line ranges, keyed by the text and the width they were measured
    /// at. The active table re-styles on EVERY keystroke, and standing up a
    /// layout manager per cell measured 10.5ms per key on a 9x6 table — the whole
    /// typing budget. Only the edited cell actually changes, so everything else
    /// is a cache hit.
    private static let lineCache: NSCache<NSString, LineBreaks> = {
        let cache = NSCache<NSString, LineBreaks>()
        cache.countLimit = 4096
        return cache
    }()

    private final class LineBreaks {
        let ranges: [NSRange]
        let hardTerminated: Set<Int>
        init(_ ranges: [NSRange], _ hardTerminated: Set<Int>) {
            self.ranges = ranges
            self.hardTerminated = hardTerminated
        }
    }

    /// - Parameter cacheKey: identity of the STYLED string, supplied by the
    ///   caller because it already builds one. nil disables caching. It must not
    ///   be derived from object identity — a freed string and a fresh one share
    ///   an address, and the cache then hands back another cell's line breaks.
    static func make(
        attributed: NSAttributedString,
        sourceLocation: Int,
        width: CGFloat,
        lineHeight: CGFloat,
        caretRange: NSRange? = nil,
        font: NSFont? = nil,
        cacheKey: String? = nil
    ) -> LiveTableCellLayout {
        let span = caretRange ?? NSRange(location: sourceLocation, length: attributed.length)
        let space = font.map {
            advance(of: NSAttributedString(string: " ", attributes: [.font: $0]))
        } ?? 0
        // Not `attributed.description`: it walks every attribute run and cost
        // more to build than the layout it was meant to save (measured).
        let key = cacheKey.map { "\(Int(width.rounded()))|\($0)" as NSString }
        if let key, let cached = lineCache.object(forKey: key) {
            return LiveTableCellLayout(
                attributed: attributed,
                sourceLocation: sourceLocation,
                width: width,
                lineHeight: lineHeight,
                lineRanges: cached.ranges,
                hardTerminated: cached.hardTerminated,
                caretRange: span,
                spaceAdvance: space
            )
        }

        var ranges: [NSRange] = []
        var hardTerminated: Set<Int> = []
        if attributed.length > 0, width > 0 {
            // Laid out one `<br>`-separated segment at a time. A hard break is
            // markup, not a newline — the row would end at a newline — so the
            // wrapper never sees one and would run the two halves together.
            var cursor = 0
            let breaks = TableCells.hardBreaks(in: attributed.string)
                + [NSRange(location: attributed.length, length: 0)]
            for hardBreak in breaks {
                let segment = NSRange(location: cursor, length: hardBreak.location - cursor)
                guard segment.length >= 0, NSMaxRange(segment) <= attributed.length else { break }
                var lines = wrap(attributed.attributedSubstring(from: segment), width: width)
                    .map { NSRange(location: segment.location + $0.location, length: $0.length) }
                // An empty segment is still a line — two breaks in a row leave a
                // blank one, and dropping it would silently swallow the break.
                if lines.isEmpty { lines = [NSRange(location: segment.location, length: 0)] }
                // The `<br>` characters ride on the line they end. They are
                // kerned to zero width, so they draw nothing and add nothing,
                // but every character of the cell has to belong to some line or
                // the caret falls through the gap.
                if hardBreak.length > 0 {
                    let last = lines.removeLast()
                    lines.append(NSRange(location: last.location, length: last.length + hardBreak.length))
                    hardTerminated.insert(ranges.count + lines.count - 1)
                }
                ranges.append(contentsOf: lines)
                cursor = NSMaxRange(hardBreak)
            }
        }
        if ranges.isEmpty {
            ranges = [NSRange(location: 0, length: attributed.length)]
        }
        if let key { lineCache.setObject(LineBreaks(ranges, hardTerminated), forKey: key) }
        return LiveTableCellLayout(
            attributed: attributed,
            sourceLocation: sourceLocation,
            width: width,
            lineHeight: lineHeight,
            lineRanges: ranges,
            hardTerminated: hardTerminated,
            caretRange: span,
            spaceAdvance: space
        )
    }

    /// Wrapped line ranges of one run of text, relative to it.
    ///
    /// One detached TextKit 1 stack: it is the only API that reports line break
    /// positions for a standalone string, it never touches the editor's layout,
    /// and `NSAttributedString.draw` goes through the same typesetter — so the
    /// breaks measured here are the breaks that get drawn.
    private static func wrap(_ text: NSAttributedString, width: CGFloat) -> [NSRange] {
        guard text.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var ranges: [NSRange] = []
        var index = 0
        let glyphCount = manager.numberOfGlyphs
        while index < glyphCount {
            var effective = NSRange(location: 0, length: 0)
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            guard effective.length > 0 else { break }
            ranges.append(manager.characterRange(forGlyphRange: effective, actualGlyphRange: nil))
            index = NSMaxRange(effective)
        }
        storage.removeLayoutManager(manager)
        return ranges
    }

    // MARK: - Measuring

    /// How far the pen moves across `text` — trailing whitespace INCLUDED.
    ///
    /// `NSAttributedString.size()` reports the inked box, which drops trailing
    /// whitespace. Measuring a caret prefix that way parks the caret before
    /// every space you type: the character reaches the file, the caret does not
    /// move, and the space reads as lost. CoreText's typographic width is the
    /// advance, which is what a caret follows.
    static func advance(of text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    /// Advance minus the trailing whitespace — what the text actually inks, and
    /// so what centring and right-alignment must measure.
    private static func inkedWidth(of text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let total = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGFloat(total - CTLineGetTrailingWhitespaceWidth(line))
    }

    // MARK: - Drawing

    /// Draw the cell with `origin` at its text top-left, honouring `alignment`.
    func draw(at origin: CGPoint, alignment: MarkdownStyler.TableAlignment) {
        for index in lineRanges.indices {
            let line = attributed.attributedSubstring(from: lineRanges[index])
            let x = origin.x + lineX(index, alignment: alignment)
            line.draw(with: CGRect(x: x, y: origin.y + CGFloat(index) * lineHeight,
                                   width: max(visibleWidth(ofLineAt: index), width),
                                   height: lineHeight),
                      options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    // MARK: - Hit-testing and caret

    /// Width a wrapped line actually inks.
    ///
    /// Trailing whitespace excluded: the space a wrap broke on stays in the
    /// line's character range but draws nothing, so counting it shifts every
    /// centred and right-aligned line by a space.
    private func visibleWidth(ofLineAt index: Int) -> CGFloat {
        guard index < lineRanges.count else { return 0 }
        return ceil(Self.inkedWidth(of: attributed.attributedSubstring(from: lineRanges[index])))
    }

    /// x of a wrapped line's left edge for the column's alignment.
    private func lineX(_ index: Int, alignment: MarkdownStyler.TableAlignment) -> CGFloat {
        guard index < lineRanges.count else { return 0 }
        let lineWidth = visibleWidth(ofLineAt: index)
        switch alignment {
        case .left:   return 0
        case .center: return max(0, width - lineWidth) / 2
        case .right:  return max(0, width - lineWidth)
        }
    }

    /// Document offset for a point in cell-local coordinates.
    ///
    /// Clamped rather than optional: a click anywhere in the cell's box has to
    /// land somewhere sensible, and the caller has already decided the point is
    /// inside this cell.
    func offset(at point: CGPoint, alignment: MarkdownStyler.TableAlignment) -> Int {
        resolve(at: point, alignment: alignment).offset
    }

    /// - Returns: the document offset, and whether the point landed at the END
    ///   of a wrapped line. That offset is also the START of the next line, and
    ///   only the click's own y says which of the two the user meant.
    func resolve(
        at point: CGPoint, alignment: MarkdownStyler.TableAlignment
    ) -> (offset: Int, upstream: Bool) {
        guard !lineRanges.isEmpty else { return (sourceLocation, false) }
        let index = min(max(0, Int(point.y / lineHeight)), lineRanges.count - 1)
        let range = lineRanges[index]
        let line = attributed.attributedSubstring(from: range)
        let localX = point.x - lineX(index, alignment: alignment)
        if localX <= 0 { return (sourceLocation + range.location, false) }

        // Walk the line's GRAPHEME boundaries and take the nearest. Stepping raw
        // UTF-16 indices would let the caret land inside a surrogate pair or
        // between a base character and its combining mark, and one keystroke
        // there writes broken UTF-16 to the file.
        let text = line.string as NSString
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var i = 0
        while true {
            let width = ceil(Self.advance(of: line.attributedSubstring(from: NSRange(location: 0, length: i))))
            let distance = abs(width - localX)
            if distance < bestDistance { bestDistance = distance; best = i }
            if i >= text.length { break }
            i = NSMaxRange(text.rangeOfComposedCharacterSequence(at: i))
        }
        let isLineEnd = best == range.length && index < lineRanges.count - 1
        return (sourceLocation + range.location + best, isLineEnd)
    }

    /// Caret rect in cell-local coordinates for a document offset.
    ///
    /// - Parameter preferUpstream: at a soft wrap, draw at the END of the line
    ///   that fills up rather than at the start of the one it spills into. The
    ///   offset is the same character either way, so nothing but the caret's
    ///   history distinguishes them — typing rightwards into the break has to
    ///   stay on the line being typed, which is what every editor does.
    func caretRect(
        forOffset offset: Int,
        alignment: MarkdownStyler.TableAlignment,
        preferUpstream: Bool = false
    ) -> CGRect? {
        // Padding BEFORE the text collapses onto its start: those spaces are
        // drawn nowhere, and the cell's first character is where the reader sees
        // the cell begin.
        if offset < sourceLocation, offset >= caretRange.location {
            return CGRect(x: lineX(0, alignment: alignment), y: 0, width: 1, height: lineHeight)
        }
        // Padding AFTER it is the one that has to move: typing a space at the
        // end of a cell lands here, and standing still there is indistinguishable
        // from the keystroke being swallowed.
        let contentEnd = sourceLocation + attributed.length
        if offset > contentEnd, offset <= NSMaxRange(caretRange) {
            let last = max(0, lineRanges.count - 1)
            let x = lineX(last, alignment: alignment)
                + visibleWidth(ofLineAt: last)
                + CGFloat(offset - contentEnd) * spaceAdvance
            return CGRect(x: x, y: CGFloat(last) * lineHeight, width: 1, height: lineHeight)
        }
        let local = offset - sourceLocation
        guard local >= 0, local <= attributed.length else { return nil }
        // A soft break's offset is both the end of one line and the start of the
        // next; `preferUpstream` is the caller's record of which one the caret
        // arrived from. Without a preference, take the line it STARTS — resolving
        // every boundary upstream put the caret on the previous line, so pressing
        // up from the head of a wrapped line stepped out of the cell entirely.
        // A hard-terminated line is never the upstream answer: past its `<br>`
        // there is only one place the caret can mean.
        let upstreamIndex: Int? = preferUpstream ? lineRanges.indices.first {
            local > lineRanges[$0].location
                && local <= NSMaxRange(lineRanges[$0])
                && !hardTerminated.contains($0)
        } : nil
        let index = upstreamIndex ?? lineRanges.firstIndex {
            local >= $0.location && local < NSMaxRange($0)
        } ?? max(0, lineRanges.count - 1)
        let range = lineRanges[index]
        // At the end of a line that wraps, sit right after the last WORD: the
        // space the break happened on still belongs to this line's range, and
        // measuring it would park the caret a space out past the text.
        if local == NSMaxRange(range), index < lineRanges.count - 1 {
            return CGRect(x: lineX(index, alignment: alignment) + visibleWidth(ofLineAt: index),
                          y: CGFloat(index) * lineHeight, width: 1, height: lineHeight)
        }
        let line = attributed.attributedSubstring(from: range)
        let upto = min(max(0, local - range.location), line.length)
        let x = lineX(index, alignment: alignment)
            + ceil(Self.advance(of: line.attributedSubstring(from: NSRange(location: 0, length: upto))))
        return CGRect(x: x, y: CGFloat(index) * lineHeight, width: 1, height: lineHeight)
    }
}
