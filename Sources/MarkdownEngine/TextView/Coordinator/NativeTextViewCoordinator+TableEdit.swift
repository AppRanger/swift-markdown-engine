//
//  NativeTextViewCoordinator+TableEdit.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Applies a `TableEditRequest` to the document. The transformation itself is
//  `MarkdownTableEditor`; this file is only the text-view mechanics — the undo
//  fence, the sanctioned mutation shape, and the guard that a stale request
//  cannot land on prose.
//
//  Both operations are INSERT-ONLY. Rewriting a row would strip `.wikiLinkID`
//  off any `[[Name]]` in it and persist the link without its UUID.
//

import AppKit

extension NativeTextViewCoordinator {
    func applyTableEdit(_ request: TableEditRequest, to textView: NSTextView) {
        guard lastAppliedTableEditID != request.id else { return }
        lastAppliedTableEditID = request.id

        guard textView.isEditable,
              !configuration.rawSourceMode,
              let storage = textView.textStorage else { return }

        let text = textView.string as NSString
        // The range came from a published geometry, which SwiftUI may re-deliver
        // after the document moved on. Require it to still name a live table
        // exactly, so a stale offset lands nowhere rather than mid-paragraph.
        guard isLiveTable(request.tableRange, in: text) else {
            return
        }

        switch request.operation {
        case .appendRow:
            guard let insertion = MarkdownTableEditor.appendRowInsertion(
                in: text, tableRange: request.tableRange
            ) else { return }
            insert([insertion], in: textView, storage: storage, actionName: "Add Table Row")

        case .appendColumn:
            let insertions = MarkdownTableEditor.appendColumnInsertions(
                in: text, tableRange: request.tableRange
            )
            guard !insertions.isEmpty else { return }
            insert(insertions, in: textView, storage: storage, actionName: "Add Table Column")
        }
    }

    /// Exact-match against the tokenizer's own table ranges. A prefix or
    /// overlapping match is not good enough: the insertion points are computed
    /// off this range's end.
    private func isLiveTable(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return false }
        return MarkdownTokenizer.parseTokensViaAST(in: text as String)
            .contains { $0.kind == .table && $0.range == range }
    }

    /// One undo step, whatever the insertion count.
    ///
    /// `insertions` arrive descending, which is also the order they are applied:
    /// editing back-to-front keeps every earlier location valid.
    private func insert(
        _ insertions: [MarkdownTableEditor.Insertion],
        in textView: NSTextView,
        storage: NSTextStorage,
        actionName: String
    ) {
        let ranges = insertions.map { NSValue(range: NSRange(location: $0.location, length: 0)) }
        let strings = insertions.map(\.text)

        // Fence both sides: without the leading break this merges into the
        // preceding typing run, and without the trailing one the next keystroke
        // merges into this — either way one Cmd+Z reverts both.
        textView.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard textView.shouldChangeText(inRanges: ranges, replacementStrings: strings) else { return }
        storage.beginEditing()
        for insertion in insertions {
            storage.replaceCharacters(
                in: NSRange(location: insertion.location, length: 0),
                with: insertion.text
            )
        }
        storage.endEditing()

        // A multi-range edit never runs the single-range delegate callback, so
        // nothing recorded what moved. `textDidChange` would otherwise fall back
        // to `NSTextStorage.editedRange`, which AppKit has already reset by now —
        // and a wrong descriptor here is what diverges the storage form from the
        // display text (see InterceptorStorageSyncTests).
        let added = insertions.reduce(0) { $0 + ($1.text as NSString).length }
        if let first = insertions.last {
            let end = insertions[0].location + added
            pendingEditedRange = NSRange(location: first.location, length: end - first.location)
            pendingTextMutation = nil
        }

        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        textView.breakUndoCoalescing()
    }
}
