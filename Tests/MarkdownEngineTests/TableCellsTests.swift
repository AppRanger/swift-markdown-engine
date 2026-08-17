//
//  TableCellsTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  The scanner has to agree with `parseTableRow` about where every cell starts
//  and ends — that equality is what lets the live form reuse the picture's
//  measured column widths. Asserted against the picture's own splitter rather
//  than against hand-written offsets.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table cell ranges")
struct TableCellsTests {

    private func tableRange(in source: String) -> NSRange? {
        MarkdownTokenizer.parseTokensViaAST(in: source)
            .first { $0.kind == .table }?.range
    }

    /// For every cell of every row, the scanned range must hold exactly the
    /// string `parseTableRow` produces for that cell.
    private func expectAgreesWithParser(_ source: String, _ label: String) throws {
        let ns = source as NSString
        let range = try #require(tableRange(in: source), "\(label): not a table")
        let rows = TableCells.rows(in: ns, tableRange: range)
        #expect(!rows.isEmpty, "\(label): no rows")

        for row in rows {
            let lineText = ns.substring(with: row.line)
            let parsed = MarkdownStyler.parseTableRow(lineText)
            #expect(row.cells.count == parsed.count, "\(label): row \(row.index) cell count")
            for (i, cell) in row.cells.enumerated() where i < parsed.count {
                #expect(ns.substring(with: cell) == parsed[i],
                        "\(label): row \(row.index) cell \(i)")
            }
        }
    }

    @Test func paddedTable() throws {
        try expectAgreesWithParser("""
        | Name | Qty |
        |---|---|
        | Nut | 3 |
        """, "padded")
    }

    @Test func packedTable() throws {
        try expectAgreesWithParser("""
        |a|b|
        |---|---|
        |1|2|
        """, "packed")
    }

    @Test func indentedTable() throws {
        try expectAgreesWithParser("""
          | a | b |
          |---|---|
          | 1 | 2 |
        """, "indented")
    }

    @Test func crlfTable() throws {
        try expectAgreesWithParser("| a | b |\r\n|---|---|\r\n| 1 | 2 |", "crlf")
    }

    @Test func raggedTable() throws {
        try expectAgreesWithParser("""
        | a | b | c |
        | --- | --- | --- |
        | 1 | 2 |
        """, "ragged")
    }

    @Test func alignedDelimiters() throws {
        try expectAgreesWithParser("""
        | a | b | c |
        | :--- | :-: | ---: |
        | 1 | 2 | 3 |
        """, "aligned")
    }

    @Test func emptyCells() throws {
        try expectAgreesWithParser("""
        | a | b |
        |---|---|
        |  |  |
        """, "empty cells")
    }

    /// An empty cell is a zero-length range positioned inside its own pipes, not
    /// a nil and not a range borrowed from a neighbour.
    @Test func emptyCellIsAZeroLengthRangeInItsOwnSlot() throws {
        let source = "| a | b |\n|---|---|\n|  |  |"
        let ns = source as NSString
        let range = try #require(tableRange(in: source))
        let rows = TableCells.rows(in: ns, tableRange: range)
        let body = try #require(rows.last)
        #expect(body.cells.count == 2)
        for (i, cell) in body.cells.enumerated() {
            #expect(cell.length == 0, "cell \(i)")
            #expect(cell.location > body.pipes[i])
            #expect(cell.location <= body.pipes[i + 1])
        }
    }

    @Test func delimiterIsAlwaysRowIndexOne() throws {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let ns = source as NSString
        let range = try #require(tableRange(in: source))
        let rows = TableCells.rows(in: ns, tableRange: range)
        #expect(rows.count == 3)
        #expect(ns.substring(with: rows[1].cells[0]) == "---")
    }

    /// Ranges are document-absolute, so a table further down the file still
    /// points at its own characters.
    @Test func rangesAreDocumentAbsolute() throws {
        let source = "intro paragraph\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        let ns = source as NSString
        let range = try #require(tableRange(in: source))
        let rows = TableCells.rows(in: ns, tableRange: range)
        #expect(ns.substring(with: rows[0].cells[0]) == "a")
        #expect(rows[0].cells[0].location > 15)
    }
}
