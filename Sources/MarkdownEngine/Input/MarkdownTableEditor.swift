//
//  MarkdownTableEditor.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Source transformations for growing a GFM table: append a row, append a
//  column. Pure text in, insertions out — no text view, no AppKit.
//
//  Two invariants hold the design up:
//
//  1. Every emitted range is ZERO-LENGTH. Rewriting a row would strip the
//     `.wikiLinkID` side-channel off any `[[Name]]` in it, persisting the link
//     without its UUID. Insert-only means the attribute travels with its own
//     characters and the restyle re-applies it from fresh metadata.
//  2. Cells are counted exactly the way `parseTableRow` counts them — split on
//     EVERY `|`, escapes included. GFM says `\|` is one escaped pipe and the
//     renderer disagrees; a mutation that were smarter than the picture would
//     insert a cell into a column the user cannot see. When `parseTableRow`
//     learns about `\|`, this follows from the same place.
//
//  The block parser only calls a line a table row when it is fully piped
//  (`|…|`, BlockParser.isTableRow), so there is no bare `a | b` style to handle.
//

import Foundation

enum MarkdownTableEditor {

    /// A zero-length edit: insert `text` at `location`.
    struct Insertion: Equatable {
        let location: Int
        let text: String
    }

    // MARK: - Scanning

    /// Content range of each line in the table, terminators excluded, in
    /// document coordinates.
    static func lineRanges(in text: NSString, tableRange: NSRange) -> [NSRange] {
        guard tableRange.length > 0, NSMaxRange(tableRange) <= text.length else { return [] }
        var result: [NSRange] = []
        let end = NSMaxRange(tableRange)
        var lineStart = tableRange.location
        var cursor = tableRange.location
        while cursor < end {
            if text.character(at: cursor) == 0x0A {          // \n
                var contentEnd = cursor
                if contentEnd > lineStart, text.character(at: contentEnd - 1) == 0x0D {
                    contentEnd -= 1                           // \r\n
                }
                result.append(NSRange(location: lineStart, length: contentEnd - lineStart))
                lineStart = cursor + 1
            }
            cursor += 1
        }
        // The token range ends at the last row's content end, so the tail is a
        // line even though no terminator follows it.
        if lineStart < end {
            result.append(NSRange(location: lineStart, length: end - lineStart))
        }
        return result
    }

    /// Document offsets of every `|` on a line.
    static func pipePositions(in text: NSString, lineRange: NSRange) -> [Int] {
        var result: [Int] = []
        for i in lineRange.location..<NSMaxRange(lineRange) where text.character(at: i) == 0x7C {
            result.append(i)
        }
        return result
    }

    /// Cells on a fully-piped line. The outer pipes bracket the row, so the
    /// count is one less than the pipe count.
    static func cellCount(in text: NSString, lineRange: NSRange) -> Int {
        max(0, pipePositions(in: text, lineRange: lineRange).count - 1)
    }

    /// The table's column count, agreeing with `parseTableSource`, which takes
    /// `max(header, delimiter)`.
    static func columnCount(in text: NSString, lines: [NSRange]) -> Int {
        guard lines.count >= 2 else { return 0 }
        return max(cellCount(in: text, lineRange: lines[0]),
                   cellCount(in: text, lineRange: lines[1]))
    }

    /// `true` when the table pads cells with a space (`| a | b |`) rather than
    /// packing them (`|a|b|`). The header decides for the whole table: the most
    /// common real shape is a padded header over a packed `|---|---|`, and that
    /// table should keep growing padded.
    static func usesPaddedCells(in text: NSString, headerRange: NSRange) -> Bool {
        guard let firstPipe = pipePositions(in: text, lineRange: headerRange).first else { return true }
        let next = firstPipe + 1
        guard next < NSMaxRange(headerRange) else { return true }
        return text.character(at: next) == 0x20
    }

    /// Leading spaces/tabs of a line, so an indented table stays indented.
    static func leadingWhitespace(in text: NSString, lineRange: NSRange) -> String {
        var result = ""
        for i in lineRange.location..<NSMaxRange(lineRange) {
            let ch = text.character(at: i)
            guard ch == 0x20 || ch == 0x09 else { break }
            result.append(ch == 0x20 ? " " : "\t")
        }
        return result
    }

    /// The terminator the table itself uses, so a CRLF document stays CRLF.
    static func lineTerminator(in text: NSString, tableRange: NSRange) -> String {
        let end = NSMaxRange(tableRange)
        var cursor = tableRange.location
        while cursor < end {
            if text.character(at: cursor) == 0x0A {
                if cursor > tableRange.location, text.character(at: cursor - 1) == 0x0D { return "\r\n" }
                return "\n"
            }
            cursor += 1
        }
        return "\n"
    }

    /// One source cell including its closing pipe, in the table's own style.
    ///
    /// An empty cell keeps a space even when packed: a bare `"|"` would render a
    /// one-column row as `||`, and `isTableRow` needs at least one character
    /// between the outer pipes — the appended row would silently fall out of the
    /// table.
    static func cellUnit(_ content: String, padded: Bool) -> String {
        if content.isEmpty { return padded ? "  |" : " |" }
        return padded ? " \(content) |" : "\(content)|"
    }

    // MARK: - Operations

    /// Append an empty row below the table.
    ///
    /// The token range ends at the last row's content end — before its newline —
    /// so `NSMaxRange` is the insertion point whether the table is followed by a
    /// blank line, another block, or nothing at all.
    static func appendRowInsertion(in text: NSString, tableRange: NSRange) -> Insertion? {
        let lines = lineRanges(in: text, tableRange: tableRange)
        guard lines.count >= 2 else { return nil }
        let columns = columnCount(in: text, lines: lines)
        guard columns > 0 else { return nil }

        let padded = usesPaddedCells(in: text, headerRange: lines[0])
        let indent = leadingWhitespace(in: text, lineRange: lines[lines.count - 1])
        let terminator = lineTerminator(in: text, tableRange: tableRange)
        let row = indent + "|" + String(repeating: cellUnit("", padded: padded), count: columns)

        return Insertion(location: NSMaxRange(tableRange), text: terminator + row)
    }

    /// Append a column on the right, one zero-length insertion per line.
    ///
    /// Returned DESCENDING by location so a caller can apply them in order
    /// without re-mapping the ones that follow.
    ///
    /// The cut point is `min(cells, columns)`, which handles the three row
    /// shapes at once: a normal row gets its cell after the trailing pipe; a
    /// ragged row is padded to the column count first, or the new value would
    /// land in a MISSING column rather than the new one; an over-long row is cut
    /// mid-line, because `parseTableSource` truncates its surplus away and an
    /// end-of-line insertion would be just as invisible.
    static func appendColumnInsertions(in text: NSString, tableRange: NSRange) -> [Insertion] {
        let lines = lineRanges(in: text, tableRange: tableRange)
        guard lines.count >= 2 else { return [] }
        let columns = columnCount(in: text, lines: lines)
        guard columns > 0 else { return [] }

        let padded = usesPaddedCells(in: text, headerRange: lines[0])
        var result: [Insertion] = []

        for (index, line) in lines.enumerated() {
            let pipes = pipePositions(in: text, lineRange: line)
            let cells = pipes.count - 1
            guard cells >= 1 else { continue }

            // A new column is left-aligned: copying a neighbour's `---:` would
            // silently right-align a column with nothing in it yet.
            let content = index == 1 ? "---" : ""
            let cut = min(cells, columns)
            let missing = max(0, columns - cells)
            let unit = cellUnit(content, padded: padded)

            result.append(Insertion(
                location: pipes[cut] + 1,
                text: String(repeating: unit, count: missing + 1)
            ))
        }

        return result.sorted { $0.location > $1.location }
    }
}
