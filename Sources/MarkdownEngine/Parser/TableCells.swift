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
        /// Every `|` on the line, in document coordinates.
        let pipes: [Int]
    }

    static func rows(in text: NSString, tableRange: NSRange) -> [Row] {
        let lines = MarkdownTableEditor.lineRanges(in: text, tableRange: tableRange)
        return lines.enumerated().compactMap { index, line in
            let pipes = MarkdownTableEditor.pipePositions(in: text, lineRange: line)
            guard pipes.count >= 2 else { return nil }
            var cells: [NSRange] = []
            for i in 0..<(pipes.count - 1) {
                cells.append(trimmed(in: text, from: pipes[i] + 1, to: pipes[i + 1]))
            }
            return Row(index: index, line: line, cells: cells, pipes: pipes)
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
}
