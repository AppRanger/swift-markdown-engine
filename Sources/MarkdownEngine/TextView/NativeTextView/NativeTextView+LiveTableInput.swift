//
//  NativeTextView+LiveTableInput.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Keys that mean something different inside a live table than they do in prose.
//

import AppKit

extension NativeTextView {
    /// ⇧↵ — a line break inside the cell the caret is in.
    ///
    /// A table row IS one line of the document: a real newline would end the row
    /// and split the table. `<br>` is the break Markdown provides for exactly
    /// this, and both forms of the table render it as a new line — the picture
    /// by expanding it, the live grid by laying the cell out one segment at a
    /// time.
    ///
    /// Written through the typing path so it is one undo step of its own and the
    /// storage keeps the descriptor of what moved.
    func insertLiveTableLineBreak() {
        let range = selectedRange()
        let markup = "<br>"
        guard shouldChangeText(in: range, replacementString: markup),
              let storage = textStorage
        else { return }
        breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: markup)
        didChangeText()
        breakUndoCoalescing()
        // After the break, not inside it: the caret belongs on the new line.
        setSelectedRange(NSRange(location: range.location + (markup as NSString).length, length: 0))
    }

    /// ⌫ / ⌦ across a `<br>` — takes the whole markup, not one character.
    ///
    /// The break is FOUR characters that draw nothing. Deleting one of them
    /// leaves `<br`, which is no longer a break, so it stops being hidden and
    /// the leftovers appear as literal text in the middle of the cell. To the
    /// reader one break is one thing, and one press has to remove all of it.
    ///
    /// - Parameter forward: ⌦ rather than ⌫.
    /// - Returns: whether a break was found and removed; false leaves the key
    ///   to its normal handling.
    func deleteLiveTableHardBreak(forward: Bool) -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let storage = textStorage else { return false }
        let text = storage.string as NSString
        // `<br />` is six characters, so a window of eight covers every spelling
        // with room to spare on both sides.
        let start = max(0, selection.location - (forward ? 0 : 8))
        let end = min(text.length, selection.location + (forward ? 8 : 0))
        guard end > start else { return false }
        let window = NSRange(location: start, length: end - start)
        let breaks = TableCells.hardBreaks(in: text.substring(with: window))
            .map { NSRange(location: start + $0.location, length: $0.length) }
        let target = forward
            ? breaks.first { $0.location == selection.location }
            : breaks.first { NSMaxRange($0) == selection.location }
        guard let target, shouldChangeText(in: target, replacementString: "") else { return false }
        breakUndoCoalescing()
        storage.replaceCharacters(in: target, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: target.location, length: 0))
        return true
    }
}
