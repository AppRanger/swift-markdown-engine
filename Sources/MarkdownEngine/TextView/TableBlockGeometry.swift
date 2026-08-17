//
//  TableBlockGeometry.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 17.08.26.
//
//  Where a rendered table's pixels are, published so an embedder can hang its
//  own chrome off them. The engine reports geometry; it draws no chrome and
//  ships no widget — same seam as CodeBlockSelection.
//

import Foundation

/// Position and size of a single rendered table currently visible in the editor.
///
/// Delivered through ``NativeTextViewWrapper/onTableGeometryChange``.
///
/// Tables the caret is inside are **not** reported: they show their raw `|`
/// source rather than a picture, so there is no rendered box to attach anything
/// to. Same rule, and the same reason, as ``CodeBlockSelection``.
public struct TableBlockGeometry: Identifiable, Sendable, Equatable {

    /// Stable while the table's text is unchanged, so a `ForEach` keeps the same
    /// view across edits elsewhere in the document. Derived from the source text
    /// and the table's occurrence index, so two identical tables still differ.
    /// Process-local — never persist it.
    public let id: Int

    /// The table's span in the editor's text. Hand it back through
    /// ``TableEditRequest`` to grow the table; do not splice it yourself.
    public let sourceRange: NSRange

    /// The table's visible box, in the editor scroll view's coordinate space —
    /// the same space as ``CodeBlockSelection/rect``, so the two compose in one
    /// overlay. Excludes the horizontal scroller strip; see ``bottomChromeHeight``.
    public let rect: CGRect

    /// Blank space the editor leaves between this table and the next block. An
    /// affordance drawn under the table has to fit inside it. Not derivable
    /// embedder-side: it follows the layout manager's line height, not the font's.
    public let gapBelow: CGFloat

    /// `true` when the table is wider than the text column and scrolls
    /// horizontally in its own view. ``rect`` is then the visible box, and the
    /// table continues past its right edge — so trailing chrome would sit on a
    /// clip boundary rather than on the table's actual end.
    public let isScrollable: Bool

    /// Height of the scroller strip reserved below the table when
    /// ``isScrollable``; zero otherwise. Chrome placed under the table belongs
    /// below this, or it lands on the scroller.
    public let bottomChromeHeight: CGFloat

    public init(
        id: Int,
        sourceRange: NSRange,
        rect: CGRect,
        gapBelow: CGFloat,
        isScrollable: Bool,
        bottomChromeHeight: CGFloat
    ) {
        self.id = id
        self.sourceRange = sourceRange
        self.rect = rect
        self.gapBelow = gapBelow
        self.isScrollable = isScrollable
        self.bottomChromeHeight = bottomChromeHeight
    }
}
