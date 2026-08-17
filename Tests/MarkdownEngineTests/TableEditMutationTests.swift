//
//  TableEditMutationTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 17.08.26.
//
//  Applying a table edit against a real text view: the text it produces, that a
//  whole column arrives as ONE undo step, and that a stale request lands
//  nowhere. Headless.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct TableEditMutationTests {
    private let source = """
    | Name | Qty |
    |---|---|
    | Nut | 3 |
    """

    private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.documentId = "doc"
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.allowsUndo = true
        textView.delegate = coordinator
        textView.string = text
        coordinator.textView = textView
        return (coordinator, textView)
    }

    private func tableRange(in text: String) -> NSRange {
        MarkdownTokenizer.parseTokensViaAST(in: text)
            .first { $0.kind == .table }?.range ?? NSRange(location: 0, length: 0)
    }

    private func request(_ operation: TableEditOperation, in text: String) -> TableEditRequest {
        TableEditRequest(documentId: "doc", tableRange: tableRange(in: text), operation: operation)
    }

    // MARK: - Text produced

    @Test func appendRowGrowsTheSource() {
        let (coordinator, textView) = makeEditor(source)
        coordinator.applyTableEdit(request(.appendRow, in: source), to: textView)
        #expect(textView.string == source + "\n|  |  |")
    }

    @Test func appendColumnGrowsEveryLine() {
        let (coordinator, textView) = makeEditor(source)
        coordinator.applyTableEdit(request(.appendColumn, in: source), to: textView)
        #expect(textView.string == """
        | Name | Qty |  |
        |---|---| --- |
        | Nut | 3 |  |
        """)
    }

    /// The whole point of the insert-only design: a link in an untouched cell
    /// keeps its characters, so the UUID side-channel travels with them.
    @Test func appendColumnLeavesExistingCellTextByteIdentical() {
        let withLink = """
        | Ref | Qty |
        |---|---|
        | [[Some Note|ABC-123]] | 3 |
        """
        let (coordinator, textView) = makeEditor(withLink)
        coordinator.applyTableEdit(request(.appendColumn, in: withLink), to: textView)
        #expect(textView.string.contains("[[Some Note|ABC-123]]"))
    }

    // MARK: - Undo

    @Test func appendRowIsASingleUndoStep() throws {
        let (coordinator, textView) = makeEditor(source)
        let undo = try #require(textView.undoManager)

        coordinator.applyTableEdit(request(.appendRow, in: source), to: textView)
        #expect(textView.string != source)

        undo.undo()
        #expect(textView.string == source, "one undo must restore the whole edit")
    }

    /// Three separate insertions, one gesture — the case that breaks if the
    /// mutation loops over `shouldChangeText` instead of batching `inRanges:`.
    @Test func appendColumnIsASingleUndoStep() throws {
        let (coordinator, textView) = makeEditor(source)
        let undo = try #require(textView.undoManager)

        coordinator.applyTableEdit(request(.appendColumn, in: source), to: textView)
        #expect(textView.string != source)

        undo.undo()
        #expect(textView.string == source, "one undo must restore all three insertions")
    }

    // MARK: - Guards

    // Cross-document requests are filtered in the wrapper's `updateNSView`, which
    // this headless harness does not run — so there is deliberately no test for
    // it here rather than a vacuous one that passes either way.

    @Test func ignoresARepeatedRequestID() {
        let (coordinator, textView) = makeEditor(source)
        let req = request(.appendRow, in: source)
        coordinator.applyTableEdit(req, to: textView)
        let afterFirst = textView.string
        coordinator.applyTableEdit(req, to: textView)
        #expect(textView.string == afterFirst, "the same request must not apply twice")
    }

    /// A range published before an edit elsewhere must not write into prose.
    @Test func ignoresAStaleRangeThatNoLongerNamesATable() {
        let (coordinator, textView) = makeEditor(source)
        let stale = TableEditRequest(
            documentId: "doc",
            tableRange: NSRange(location: 0, length: 5),
            operation: .appendRow
        )
        coordinator.applyTableEdit(stale, to: textView)
        #expect(textView.string == source)
    }

    @Test func ignoresARangeBeyondTheDocument() {
        let (coordinator, textView) = makeEditor(source)
        let bogus = TableEditRequest(
            documentId: "doc",
            tableRange: NSRange(location: 0, length: (source as NSString).length + 50),
            operation: .appendColumn
        )
        coordinator.applyTableEdit(bogus, to: textView)
        #expect(textView.string == source)
    }

    @Test func refusesWhileReadOnly() {
        let (coordinator, textView) = makeEditor(source)
        textView.isEditable = false
        coordinator.applyTableEdit(request(.appendRow, in: source), to: textView)
        #expect(textView.string == source)
    }

    /// In raw-source mode the document shows `[[Name|UUID]]`, where the `|` would
    /// be counted as a cell delimiter.
    @Test func refusesInRawSourceMode() {
        let (coordinator, textView) = makeEditor(source)
        var config = MarkdownEditorConfiguration.default
        config.rawSourceMode = true
        coordinator.configuration = config
        coordinator.applyTableEdit(request(.appendRow, in: source), to: textView)
        #expect(textView.string == source)
    }

    // MARK: - Round trip

    /// The grown table must still be one table, or the next affordance click
    /// would be computed against a range that no longer exists.
    @Test func grownTableIsStillOneTable() {
        let (coordinator, textView) = makeEditor(source)
        coordinator.applyTableEdit(request(.appendRow, in: source), to: textView)
        coordinator.applyTableEdit(request(.appendColumn, in: textView.string), to: textView)

        let tokens = MarkdownTokenizer.parseTokensViaAST(in: textView.string)
            .filter { $0.kind == .table }
        #expect(tokens.count == 1)
        #expect(tokens[0].range.length == (textView.string as NSString).length)

        let parsed = MarkdownStyler.parseTableSource(textView.string)
        #expect(parsed?.alignments.count == 3)
        #expect(parsed?.rows.count == 2)
    }
}

/// A row with fewer cells than the header draws the rest empty, so the grid
/// offers a cell the source does not contain — there is nothing in it to put a
/// caret on, and the click fell into the neighbouring cell instead.
@Suite("Padding a short row")
struct TableShortRowPaddingTests {
    private let table = "| a | b |\n|---|---|\n| 1   |"

    private func padded(_ source: String) throws -> (String, [Int]) {
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        let lines = MarkdownTableEditor.lineRanges(in: ns, tableRange: range)
        let last = try #require(lines.last)
        let result = try #require(MarkdownTableEditor.padRowInsertion(
            in: ns, tableRange: range, lineRange: last
        ))
        let out = NSMutableString(string: source)
        out.insert(result.insertion.text, at: result.insertion.location)
        return (out as String, result.caretOffsets)
    }

    @Test func theMissingCellBecomesReal() throws {
        let (result, _) = try padded(table)
        #expect(result == "| a | b |\n|---|---|\n| 1   |  |")
        let ns = result as NSString
        let rows = TableCells.rows(in: ns, tableRange: NSRange(location: 0, length: ns.length))
        let row = try #require(rows.last)
        #expect(row.cells.count == 2)
    }

    /// The caret has to land INSIDE the new cell, or the click still misses.
    @Test func theCaretLandsInTheNewCell() throws {
        let (result, carets) = try padded(table)
        let ns = result as NSString
        let rows = TableCells.rows(in: ns, tableRange: NSRange(location: 0, length: ns.length))
        let span = try #require(rows.last?.spans.last)
        let caret = try #require(carets.first)
        #expect(caret >= span.location && caret <= NSMaxRange(span))
    }

    /// Nothing to do when the row is already full — a click must not rewrite the
    /// file for no reason.
    @Test func aFullRowIsLeftAlone() throws {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        let lines = MarkdownTableEditor.lineRanges(in: ns, tableRange: range)
        let last = try #require(lines.last)
        #expect(MarkdownTableEditor.padRowInsertion(
            in: ns, tableRange: range, lineRange: last
        ) == nil)
    }
}
