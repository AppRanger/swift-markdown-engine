//
//  TableSourceEditTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Growing a table has to survive the shapes people actually write: packed and
//  padded cells, aligned delimiters, indented tables, CRLF, ragged and
//  over-long rows. Every case here also re-parses the RESULT, because a row
//  that stops satisfying `isTableRow` would silently drop out of the table.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table source edits")
struct TableSourceEditTests {

    /// Runs the operation the way the coordinator will: locate the table by
    /// tokenizing, then apply the insertions front-to-back.
    private func apply(_ source: String, _ op: (NSString, NSRange) -> [MarkdownTableEditor.Insertion]) throws -> String {
        let ns = source as NSString
        let tableRange = try #require(Self.tableRange(in: source), "no table token")
        let result = NSMutableString(string: ns)
        for insertion in op(ns, tableRange) {
            result.insert(insertion.text, at: insertion.location)
        }
        return result as String
    }

    private func appendRow(_ source: String) throws -> String {
        try apply(source) { text, range in
            MarkdownTableEditor.appendRowInsertion(in: text, tableRange: range).map { [$0] } ?? []
        }
    }

    private func appendColumn(_ source: String) throws -> String {
        try apply(source) { MarkdownTableEditor.appendColumnInsertions(in: $0, tableRange: $1) }
    }

    /// The engine's own idea of where the table is — never a hand-written range.
    private static func tableRange(in source: String) -> NSRange? {
        MarkdownTokenizer.parseTokensViaAST(in: source)
            .first { $0.kind == .table }?
            .range
    }

    /// The result must still parse as a table with the expected shape, or the
    /// edit produced valid-looking text the renderer disagrees with.
    private func expectShape(_ source: String, columns: Int, bodyRows: Int, _ label: String) throws {
        let range = try #require(Self.tableRange(in: source), "\(label): result is not a table any more")
        #expect(range.length == (source as NSString).length, "\(label): table no longer spans the whole source")
        let parsed = try #require(MarkdownStyler.parseTableSource(source), "\(label): parse failed")
        #expect(parsed.alignments.count == columns, "\(label): columns")
        #expect(parsed.rows.count == bodyRows, "\(label): body rows")
    }

    // MARK: - Append row

    @Test func appendsRowToAPaddedTable() throws {
        let result = try appendRow("""
        | Name | Qty |
        |---|---|
        | Nut | 3 |
        """)
        #expect(result == """
        | Name | Qty |
        |---|---|
        | Nut | 3 |
        |  |  |
        """)
        try expectShape(result, columns: 2, bodyRows: 2, "padded")
    }

    @Test func appendsRowToAPackedTable() throws {
        let result = try appendRow("""
        |a|b|
        |---|---|
        |1|2|
        """)
        #expect(result == """
        |a|b|
        |---|---|
        |1|2|
        | | |
        """)
        try expectShape(result, columns: 2, bodyRows: 2, "packed")
    }

    /// A packed one-column table is where a bare `"|"` cell would produce `||`,
    /// which `isTableRow` rejects — the row would fall out of the table.
    @Test func appendedRowStaysARowInAOneColumnPackedTable() throws {
        let result = try appendRow("""
        |a|
        |---|
        """)
        #expect(result == """
        |a|
        |---|
        | |
        """)
        try expectShape(result, columns: 1, bodyRows: 1, "one column packed")
    }

    @Test func appendsRowToATableWithNoBodyRows() throws {
        let result = try appendRow("""
        | a | b |
        |---|---|
        """)
        try expectShape(result, columns: 2, bodyRows: 1, "header only")
    }

    @Test func appendedRowKeepsTheIndent() throws {
        let result = try appendRow("""
          | a | b |
          |---|---|
          | 1 | 2 |
        """)
        #expect(result.hasSuffix("\n  |  |  |"))
    }

    @Test func appendedRowKeepsCRLF() throws {
        let source = "| a | b |\r\n|---|---|\r\n| 1 | 2 |"
        let result = try appendRow(source)
        #expect(result == source + "\r\n|  |  |")
        #expect(!result.contains("\n|  |  |".replacingOccurrences(of: "\r", with: "")) || result.contains("\r\n|  |  |"))
    }

    @Test func appendedRowMatchesTheWidestOfHeaderAndDelimiter() throws {
        // Delimiter declares three columns, header only two — parseTableSource
        // takes the max, so the appended row must have three.
        let result = try appendRow("""
        | a | b |
        |---|---|---|
        | 1 | 2 |
        """)
        try expectShape(result, columns: 3, bodyRows: 2, "delimiter wider")
        #expect(result.hasSuffix("|  |  |  |"))
    }

    @Test func trailingSpacesAfterTheLastPipeDoNotBreakTheInsert() throws {
        let result = try appendRow("| a | b |\n|---|---|\n| 1 | 2 |   ")
        try expectShape(result, columns: 2, bodyRows: 2, "trailing spaces")
    }

    // MARK: - Append column

    @Test func appendsColumnToAPaddedTable() throws {
        let result = try appendColumn("""
        | Name | Qty |
        |---|---|
        | Nut | 3 |
        """)
        #expect(result == """
        | Name | Qty |  |
        |---|---| --- |
        | Nut | 3 |  |
        """)
        try expectShape(result, columns: 3, bodyRows: 1, "padded")
    }

    @Test func appendsColumnToAPackedTable() throws {
        let result = try appendColumn("""
        |a|b|
        |---|---|
        |1|2|
        """)
        #expect(result == """
        |a|b| |
        |---|---|---|
        |1|2| |
        """)
        try expectShape(result, columns: 3, bodyRows: 1, "packed")
    }

    /// A new column is left-aligned on purpose; inheriting `---:` would
    /// right-align a column with nothing in it.
    @Test func newColumnIsLeftAlignedNotInherited() throws {
        let result = try appendColumn("""
        | a | b | c |
        | :--- | :-: | ---: |
        | 1 | 2 | 3 |
        """)
        let parsed = try #require(MarkdownStyler.parseTableSource(result))
        #expect(parsed.alignments == [.left, .center, .right, .left])
    }

    /// A ragged row needs the gap filled first, or the new value lands in a
    /// missing column instead of the new one.
    @Test func raggedRowIsPaddedBeforeTheNewColumn() throws {
        let result = try appendColumn("""
        | a | b | c |
        | --- | --- | --- |
        | 1 | 2 |
        """)
        try expectShape(result, columns: 4, bodyRows: 1, "ragged")
        let parsed = try #require(MarkdownStyler.parseTableSource(result))
        #expect(parsed.rows[0].count == 4)
        #expect(parsed.rows[0][0] == "1")
        #expect(parsed.rows[0][1] == "2")
        #expect(parsed.rows[0][2] == "")
        #expect(parsed.rows[0][3] == "")
    }

    /// An over-long row is cut mid-line: its surplus is already invisible, and
    /// appending at end-of-line would make the new cell invisible too.
    @Test func overlongRowGetsTheNewCellWhereItIsVisible() throws {
        let result = try appendColumn("""
        | a | b |
        | --- | --- |
        | 1 | 2 | 3 |
        """)
        let parsed = try #require(MarkdownStyler.parseTableSource(result))
        #expect(parsed.alignments.count == 3)
        // The visible cells are the first three: 1, 2, and the new empty one.
        #expect(parsed.rows[0][0] == "1")
        #expect(parsed.rows[0][1] == "2")
        #expect(parsed.rows[0][2] == "")
    }

    @Test func appendsColumnToAOneColumnTable() throws {
        let result = try appendColumn("""
        | a |
        |---|
        """)
        try expectShape(result, columns: 2, bodyRows: 0, "one column")
    }

    @Test func appendedColumnKeepsCRLF() throws {
        let result = try appendColumn("| a | b |\r\n|---|---|\r\n| 1 | 2 |")
        #expect(result.contains("\r\n"))
        #expect(!result.contains("\n\n"))
        try expectShape(result, columns: 3, bodyRows: 1, "crlf")
    }

    @Test func columnInsertionsAreDescendingSoTheyApplyInOrder() throws {
        let ns = """
        | a | b |
        |---|---|
        | 1 | 2 |
        """ as NSString
        let range = try #require(Self.tableRange(in: ns as String))
        let insertions = MarkdownTableEditor.appendColumnInsertions(in: ns, tableRange: range)
        #expect(insertions.count == 3)
        #expect(insertions.map(\.location) == insertions.map(\.location).sorted(by: >))
    }

    // MARK: - Parser-agreement traps

    /// The renderer splits on EVERY pipe, escapes included. The mutation has to
    /// agree, or it would insert into a column the picture does not show. When
    /// `parseTableRow` learns about `\|`, this expectation moves with it.
    @Test func escapedPipeCountsAsADelimiterLikeTheRenderer() throws {
        let source = """
        | a \\| b | c |
        | --- | --- |
        """
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        #expect(parsed.header.count == 3, "renderer sees three cells")
        let result = try appendColumn(source)
        let after = try #require(MarkdownStyler.parseTableSource(result))
        #expect(after.alignments.count == 4, "mutation agrees with the renderer")
    }

    /// A pipe inside a code span is a delimiter to both GFM and this parser —
    /// nothing special to do, pinned so a future change is deliberate.
    @Test func codeSpanPipeNeedsNoSpecialCase() throws {
        let source = """
        | `a|b` | c |
        | --- | --- | --- |
        """
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        #expect(parsed.header.count == 3)
        let result = try appendColumn(source)
        try expectShape(result, columns: 4, bodyRows: 0, "code span")
    }

    // MARK: - Guards

    @Test func refusesWhenThereIsNoDelimiterRow() {
        let ns = "| a | b |" as NSString
        let range = NSRange(location: 0, length: ns.length)
        #expect(MarkdownTableEditor.appendRowInsertion(in: ns, tableRange: range) == nil)
        #expect(MarkdownTableEditor.appendColumnInsertions(in: ns, tableRange: range).isEmpty)
    }

    @Test func refusesAnEmptyRange() {
        let ns = "| a | b |\n|---|---|" as NSString
        #expect(MarkdownTableEditor.appendRowInsertion(in: ns, tableRange: NSRange(location: 0, length: 0)) == nil)
    }

    @Test func refusesARangeBeyondTheText() {
        let ns = "| a | b |\n|---|---|" as NSString
        let bogus = NSRange(location: 0, length: ns.length + 10)
        #expect(MarkdownTableEditor.appendRowInsertion(in: ns, tableRange: bogus) == nil)
        #expect(MarkdownTableEditor.appendColumnInsertions(in: ns, tableRange: bogus).isEmpty)
    }
}
