//
//  NativeTextViewCoordinator+CodeBlocks.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Tracks code-block selections in the document so the host can render the
//  small "copy code" button overlay on top of every fenced code block. Skips
//  blocks the caret is currently inside (`activeTokenIndices`) to avoid the
//  button overlapping the cursor while editing.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Clears code overlays and their parse receipt before a document switch.
    /// This is intentionally synchronous: the native text view still contains
    /// the outgoing source until the incoming rebuild begins.
    func invalidateCodeBlockSelectionCache() {
        let source = textView?.string ?? ""
        let parseVersion = cachedCodeBlockTokenCache?.parseVersion ?? parsedDocumentVersion
        let outgoingDocumentId = cachedCodeBlockTokenCache?.documentId ?? documentId
        cachedCodeBlockTokenCache = nil
        lastCodeSelKey = nil
        publishCodeBlockSelection(
            [],
            documentId: outgoingDocumentId,
            source: source,
            parseVersion: parseVersion
        )
    }

    func updateCodeBlockSelection(textView: NSTextView, parsed: ParsedDocument? = nil) {
        guard let textContainer = textView.textContainer,
              let documentId else {
            publishCodeBlockSelection([], documentId: nil, source: textView.string, parseVersion: parsedDocumentVersion)
            return
        }

        let source = textView.string
        guard !configuration.rawSourceMode else {
            cachedCodeBlockTokenCache = nil
            lastCodeSelKey = nil
            publishCodeBlockSelection([], documentId: documentId, source: source, parseVersion: parsed?.version ?? parsedDocumentVersion)
            return
        }
        let tokenCache: CodeBlockTokenCache
        if let parsed {
            guard parsed.source == source else {
                // A caller can hold a parsed result across an async hop. It
                // is not safe to relabel that result with the newer native
                // source, even when fenced contents happen to match.
                cachedCodeBlockTokenCache = nil
                lastCodeSelKey = nil
                publishCodeBlockSelection([], documentId: documentId, source: source, parseVersion: parsed.version)
                return
            }
            // Indexed pairs come from the parse's single classification pass —
            // no per-call full-token filter.
            tokenCache = CodeBlockTokenCache(
                documentId: documentId,
                source: parsed.source,
                parseVersion: parsed.version,
                tokens: parsed.codeBlockTokensWithIndices
            )
            cachedCodeBlockTokenCache = tokenCache
        } else {
            // A no-parse refresh is allowed only for the exact native source
            // and document that created its tokens. Fail closed after any
            // switch or delayed callback instead of guessing from equal code.
            guard let cached = cachedCodeBlockTokenCache,
                  cached.documentId == documentId,
                  cached.source == source else {
                cachedCodeBlockTokenCache = nil
                lastCodeSelKey = nil
                publishCodeBlockSelection([], documentId: documentId, source: source, parseVersion: parsedDocumentVersion)
                return
            }
            tokenCache = cached
        }

        let nsText = source as NSString
        let scrollOffset = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero

        // Identical inputs → identical selections. The delegate path calls
        // this twice per keystroke (selection change + textDidChange) and on
        // every caret move; skip the substring/language/viewRect work when
        // nothing relevant changed. Calls without `parsed` (document switch,
        // scroll hooks) always recompute.
        //
        // The key must include the FULL active-token set, not just its code
        // intersection: a caret move INTO a standalone block (block-LaTeX /
        // table) toggles that block between its rendered image and raw source
        // — a real height change that shifts a code block below it to a new Y
        // — while leaving version, scroll, width, and the code∩active set
        // unchanged. Keying on the whole active set makes any such toggle
        // (the only same-version event that moves layout) recompute. Text
        // edits are covered by the bumped version; the twice-per-keystroke
        // redundancy still dedupes because both calls share one active set.
        if let parsed {
            let key = (parsed.version, scrollOffset.y, textContainer.containerSize.width,
                       activeTokenIndices)
            if let last = lastCodeSelKey, last == key { return }
            lastCodeSelKey = key
        } else {
            lastCodeSelKey = nil
        }

        // One-shot full-document layout per document; fixes stale Y from TextKit 2's lazy layout without per-update cost.
        // Not on open: `rebuildTextStorageAndStyle` claims the flag up front, its own ensureLayout is this one.
        if !didEnsureLayoutForCurrentDocument, let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            didEnsureLayoutForCurrentDocument = true
        }

        // Only on-screen code blocks have a visible copy button. Computing a
        // viewRect (and copying the code) for every block in the document is
        // O(doc) and dominates large files; cull to the laid-out viewport range
        // — scroll hooks recompute as blocks come into view.
        let visibleRange: NSRange? = {
            guard let tlm = textView.textLayoutManager,
                  let vp = tlm.textViewportLayoutController.viewportRange else { return nil }
            let start = tlm.offset(from: tlm.documentRange.location, to: vp.location)
            return NSRange(location: start, length: tlm.offset(from: vp.location, to: vp.endLocation))
        }()

        let selections: [CodeBlockSelection] = tokenCache.tokens.compactMap { originalIndex, token in
            guard !activeTokenIndices.contains(originalIndex) else { return nil }
            // Cached tokens can be stale for one async hop after a document swap
            // (shorter new text, queued update still holding the old parse). Skip
            // out-of-bounds tokens; the next parse refreshes the cache.
            guard NSMaxRange(token.range) <= nsText.length,
                  NSMaxRange(token.contentRange) <= nsText.length else { return nil }
            if let visibleRange, NSIntersectionRange(token.range, visibleRange).length == 0 { return nil }
            guard var boundingRect = textView.viewRect(forCharacterRange: token.range, using: layoutBridge) else { return nil }

            boundingRect.origin.x = textView.frame.origin.x + textView.textContainerOrigin.x - scrollOffset.x
            boundingRect.size.width = textContainer.containerSize.width

            return CodeBlockSelection(
                id: originalIndex,
                rect: boundingRect,
                language: MarkdownTokenizer.extractLanguage(from: token, in: source),
                code: nsText.substring(with: token.contentRange),
                sourceRange: token.range
            )
        }

        publishCodeBlockSelection(
            selections,
            documentId: documentId,
            source: source,
            parseVersion: tokenCache.parseVersion
        )
    }

    private func publishCodeBlockSelection(
        _ selections: [CodeBlockSelection],
        documentId: String?,
        source: String,
        parseVersion: UInt64
    ) {
        onCodeBlockSelectionChange?(selections)
        if let documentId {
            onCodeBlockSelectionUpdate?(
                CodeBlockSelectionUpdate(
                    editorId: editorId,
                    editorSessionId: codeBlockReceiptSessionId,
                    documentId: documentId,
                    source: source,
                    parseVersion: parseVersion,
                    selections: selections
                )
            )
        }
    }
}
