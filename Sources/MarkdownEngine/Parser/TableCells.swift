//
//  TableCells.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Where each cell's TEXT sits in the document, as ranges rather than strings.
//
//  The bitmap path splits rows into substrings and throws the offsets away, so
//  nothing could point at a cell. The live (editable) form has to — it positions
//  each cell's glyphs and hides everything between them. Cells are trimmed the
//  same way `parseTableRow` trims them, so both forms agree on where a cell
//  begins down to the character.
//

import Foundation

enum TableCells {
    /// One source line of a table. `index == 1` is always the delimiter row.
    struct Row {
        let index: Int
        /// The line's content range, terminator excluded.
        let line: NSRange
        /// Trimmed content range of each cell, left to right.
        let cells: [NSRange]
        /// The same cells UNTRIMMED — everything between two pipes, padding
        /// included. The caret has to be able to stand in that padding: typing a
        /// space at the end of a cell writes into it, and judging the caret on
        /// the trimmed range clamped it back onto the last letter, so the space
        /// went into the file while the caret never moved.
        let spans: [NSRange]
        /// Every `|` on the line, in document coordinates.
        let pipes: [Int]
    }

    static func rows(in text: NSString, tableRange: NSRange) -> [Row] {
        let lines = MarkdownTableEditor.lineRanges(in: text, tableRange: tableRange)
        return lines.enumerated().compactMap { index, line in
            let pipes = MarkdownTableEditor.pipePositions(in: text, lineRange: line)
            guard pipes.count >= 2 else { return nil }
            var cells: [NSRange] = []
            var spans: [NSRange] = []
            for i in 0..<(pipes.count - 1) {
                let start = pipes[i] + 1
                let end = pipes[i + 1]
                cells.append(trimmed(in: text, from: start, to: end))
                spans.append(NSRange(location: start, length: end - start))
            }
            return Row(index: index, line: line, cells: cells, spans: spans, pipes: pipes)
        }
    }

    /// Content between two pipes with surrounding spaces and tabs dropped —
    /// `parseTableRow` trims each cell, so an untrimmed range would put the
    /// live form's glyphs one space left of the picture's.
    private static func trimmed(in text: NSString, from start: Int, to end: Int) -> NSRange {
        var lower = start
        var upper = end
        while lower < upper, isSpaceOrTab(text.character(at: lower)) { lower += 1 }
        while upper > lower, isSpaceOrTab(text.character(at: upper - 1)) { upper -= 1 }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func isSpaceOrTab(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    /// Every `<br>` in `text`, as ranges.
    ///
    /// A table row IS one line — a newline inside a cell would end the row — so
    /// the break has to be written as markup. `<br>` is what GFM defines and
    /// what every other editor writes there.
    ///
    /// Matches `<br>`, `<br/>` and `<br />` in any case, and nothing else: a
    /// looser scan would swallow `<brand>` and eat a word.
    static func hardBreaks(in text: String) -> [NSRange] {
        let ns = text as NSString
        var result: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let remaining = NSRange(location: cursor, length: ns.length - cursor)
            let open = ns.range(of: "<br", options: [.caseInsensitive], range: remaining)
            guard open.location != NSNotFound else { break }
            var end = NSMaxRange(open)
            while end < ns.length, isSpaceOrTab(ns.character(at: end)) { end += 1 }
            if end < ns.length, ns.character(at: end) == 0x2F { end += 1 }   // "/"
            while end < ns.length, isSpaceOrTab(ns.character(at: end)) { end += 1 }
            if end < ns.length, ns.character(at: end) == 0x3E {              // ">"
                result.append(NSRange(location: open.location, length: end + 1 - open.location))
                cursor = end + 1
            } else {
                cursor = NSMaxRange(open)
            }
        }
        return result
    }
}
