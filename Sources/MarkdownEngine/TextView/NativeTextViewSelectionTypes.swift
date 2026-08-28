//
//  NativeTextViewSelectionTypes.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Public selection / replacement value types exposed by NativeTextViewWrapper.
//

import Foundation

/// A range of text occupied by a wiki-link `[[Name]]`, in both the display
/// and (where known) the storage coordinate systems.
public struct WikiLinkSelection: Sendable {
    /// Range of the link in the document the user is editing (display form).
    public let displayRange: NSRange
    /// Equivalent range in the underlying storage form `[[Name|<id>]]`,
    /// or `nil` when the storage range is unknown / the link is new.
    public let storageRange: NSRange?
    /// Plain text the user will see inside the brackets — used by embedders
    /// to seed a rename popover or autocomplete.
    public let placeholder: String

    public init(displayRange: NSRange, storageRange: NSRange?, placeholder: String) {
        self.displayRange = displayRange
        self.storageRange = storageRange
        self.placeholder = placeholder
    }
}

/// Which kind of inline token the caret is currently inside.
public enum InlineSelectionKind: Sendable {
    /// A `[[Name]]` wiki-link.
    case wikiLink
    /// A `![[Name]]` embedded-image reference.
    case imageEmbed
}

/// Snapshot of the inline token the caret is inside, delivered through
/// ``NativeTextViewWrapper/onInlineSelectionChange``.
public struct InlineSelectionState: Sendable {
    /// Whether the active token is a wiki-link or an image embed.
    public let kind: InlineSelectionKind
    /// Range and seed text of the active inline token.
    public let selection: WikiLinkSelection

    public init(kind: InlineSelectionKind, selection: WikiLinkSelection) {
        self.kind = kind
        self.selection = selection
    }
}

/// A keyboard command forwarded to an open inline preview (the `[[…]]` autocomplete)
/// via ``NativeTextViewWrapper/onInlinePreviewKey``. The embedder returns `true` to
/// consume the key (it drove its list), or `false` to let the editor handle it normally.
public enum InlinePreviewKey: Sendable {
    case moveUp, moveDown, confirm, confirmAndOpen, cancel
}

/// Request to replace an inline token's source with a new storage fragment.
///
/// Embedders push one of these into
/// ``NativeTextViewWrapper/pendingInlineReplacement`` to commit the result of
/// a rename / autocomplete UI. The engine applies the replacement, restores
/// the caret past it, and clears the binding.
public struct InlineReplacementRequest: Sendable {
    /// Stable identifier so the engine can detect already-applied requests
    /// across SwiftUI re-renders.
    public let id: UUID
    /// Document the replacement targets. Ignored if it doesn't match the
    /// editor's current `documentId` (prevents cross-document writes).
    public let documentId: String
    /// Inline-token range being replaced.
    public let selection: WikiLinkSelection
    /// New storage-form text, e.g. `"[[New Name|<id>]]"` or
    /// `"![[image-name]]"`.
    public let storageFragment: String
    /// `true` when the fragment is a `![[…]]` image embed and the engine
    /// should treat it as a standalone block.
    public let isImageEmbedMode: Bool

    public init(
        id: UUID = UUID(),
        documentId: String,
        selection: WikiLinkSelection,
        storageFragment: String,
        isImageEmbedMode: Bool
    ) {
        self.id = id
        self.documentId = documentId
        self.selection = selection
        self.storageFragment = storageFragment
        self.isImageEmbedMode = isImageEmbedMode
    }
}

/// A guarded, synchronous replacement of a displayed editor range.
///
/// This is intended for structural commands such as moving a Markdown block.
/// `expectedStorage` makes queued requests safe: the engine ignores a request
/// after any intervening edit or document switch. `resultingStorage` is the
/// complete post-edit Markdown source; the engine renders and validates it
/// before changing native storage, including hidden wiki-link identifiers.
/// Ranges are UTF-16 `NSRange` values in the rendered editor. Post this as
/// `userInfo["request"]` on ``MarkdownEditorBus/applyTextReplacementRequest``.
public struct MarkdownTextReplacementRequest: Sendable {
    /// Correlates the completion acknowledgement with this request.
    public let id: UUID
    /// Identifies one editor instance. Supply a stable unique value when more
    /// than one editor can display the same document.
    public let editorId: String
    public let documentId: String
    public let expectedStorage: String
    public let resultingStorage: String
    public let displayRange: NSRange
    public let replacementDisplay: String
    public let resultingDisplaySelection: NSRange
    public let undoActionName: String

    public init(id: UUID = UUID(), editorId: String = "default", documentId: String, expectedStorage: String,
                resultingStorage: String, displayRange: NSRange, replacementDisplay: String,
                resultingDisplaySelection: NSRange, undoActionName: String) {
        self.id = id
        self.editorId = editorId
        self.documentId = documentId
        self.expectedStorage = expectedStorage
        self.resultingStorage = resultingStorage
        self.displayRange = displayRange
        self.replacementDisplay = replacementDisplay
        self.resultingDisplaySelection = resultingDisplaySelection
        self.undoActionName = undoActionName
    }
}

/// The synchronous outcome posted as `userInfo["result"]` after a
/// ``MarkdownTextReplacementRequest`` is handled.
public enum MarkdownTextReplacementResult: Sendable {
    case applied(id: UUID, editorId: String, documentId: String, storage: String)
    case rejected(id: UUID, editorId: String, documentId: String, reason: MarkdownTextReplacementRejection)
}

/// Why a structural text replacement was safely ignored.
public enum MarkdownTextReplacementRejection: Sendable {
    case wrongDocument, wrongEditor, notEditable, markedText, writingToolsActive
    case invalidDisplayRange, mismatchedStorage, mismatchedCoordinates
    case invalidSelection, deniedByTextView
}
