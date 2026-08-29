//
//  NativeTextViewCoordinator+Restyling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Re-tokenization, paragraph-scoped restyling, and the inline-replacement
//  pipeline. The TextDelegate extension decides WHEN and on WHICH ranges to
//  restyle; this extension owns the tokenize cache and the actual call into
//  `TextStylingService`.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Atomically rebuilds contents + base attrs + Markdown styling from storage-form `text`.
    func rebuildTextStorageAndStyle(
        _ textView: NSTextView,
        from text: String,
        invalidateLayout: Bool = false
    ) {
        // Suppress the re-entrant textViewDidChangeSelection that `textView.string =`
        // and the setAttributedString transfer below fire synchronously (71ms of
        // redundant styling on a 346k note); the necessary side effect is replayed once
        // at the end of this method.
        isRebuildingDocument = true
        defer { isRebuildingDocument = false }
        // A rebuild means a different document (or a mode flip): drop the caret
        // ink resolved for the old one instead of carrying it into this text.
        resolvedCaretColor = nil
        // Storage is raw Markdown; only wiki links transform on display.
        // In raw source mode display IS storage — no transform, no metadata.
        let services = configuration.services
        let rawMode = configuration.rawSourceMode
        let displayText: String
        if rawMode {
            displayText = text
            wikiLinkMetadata = [:]
        } else {
            let displayState = WikiLinkService.makeDisplayState(from: text) { services.wikiLinks.name(forID: $0) }
            displayText = displayState.display
            wikiLinkMetadata = displayState.metadata
        }

        // Claimed BEFORE the assignment: `textView.string =` re-enters
        // textViewDidChangeSelection synchronously, whose updateCodeBlockSelection
        // laid out the whole (still unstyled) document — 141ms / 7714 fragments that
        // the ensureLayout below rebuilds from scratch anyway. This rebuild's own
        // ensureLayout IS that one-shot per-document layout.
        didEnsureLayoutForCurrentDocument = true
        if textView.string != displayText {
            textView.string = displayText
            parseGeneration &+= 1
        }
        lastSyncedText = text
        lastComputedStorage = text
        previousDisplayLength = (displayText as NSString).length
        let nsDisplay = displayText as NSString
        // Fresh document baseline: drop the incremental parse state and reseed
        // the backtick census (a stale count from the previous document would
        // force a spurious full-document restyle on the first keystroke).
        parseState.invalidate()
        pendingBacktickWindow = nil
        backtickCensusNeedsRescan = false
        previousBacktickCount = MarkdownDetection.tripleBacktickCount(in: nsDisplay)
        let fullRange = NSRange(location: 0, length: nsDisplay.length)

        let (baseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: configuration.theme.bodyText,
            .paragraphStyle: paragraph
        ]
        // ── Root cause & fix (2026-07) ────────────────────────────────────────
        // CPU+page-fault instrumentation proved the first per-process open of a large
        // note spent 12.5s of PURE CPU (blocked=2ms), writing 69k attributes to the LIVE
        // TextKit-2 storage and faulting in 315k pages / ~5GB; a later open with warm
        // pages does the identical work in 78ms. So the whole styled string is built on a
        // DETACHED NSMutableAttributedString and handed to the live storage in ONE
        // transfer — the expensive first-touch happens off the layout-connected storage.
        let built = NSMutableAttributedString(string: displayText)
        built.setAttributes(baseAttrs, range: fullRange)

        // Kept for the end-of-rebuild selection replay (see below); raw mode leaves it nil.
        var parsedForReplay: ParsedDocument?
        if rawMode {
            // Base attributes only — the source stays verbatim and unstyled.
            activeTokenIndices = []
        } else {
            let parsed = parsedDocument(for: displayText)
            parsedForReplay = parsed
            let tokens = parsed.tokens
            // Hide caret from styling when read-only, else clicks reveal raw token syntax.
            let caretLocation = textView.isEditable ? textView.selectedRange().location : -1
            activeTokenIndices = activeTokenIndices(
                parsed: parsed,
                selection: textView.selectedRange(),
                in: nsDisplay,
                suppressed: !textView.isEditable
            )

            let ranges = MarkdownStyler.styleAttributes(
                text: displayText,
                fontName: fontName,
                fontSize: fontSize,
                layoutBridge: layoutBridge,
                caretLocation: caretLocation,
                // Selection-revealed syntax (task checkboxes) needs the full
                // range, not just the caret; read-only suppresses it like the caret.
                selection: textView.isEditable ? textView.selectedRange() : nil,
                activeTokenIndices: activeTokenIndices,
                // FIX: apply .wikiLinkID attributes on load/node-switch too. Without this the uuid
                // survived only in the range-keyed wikiLinkMetadata; once a later writeback shifted a
                // link's range the metadata key missed and makeStorageState wrote [[Name]] (uuid lost).
                // wikiLinkMetadata was just refreshed by makeDisplayState above, so ranges match here.
                wikiLinkIDProvider: { [weak self] range in self?.wikiLinkID(for: range) },
                precomputedTokens: tokens,
                classified: parsed.classified,
                // Same parse the tokens came from; without it the styler ran the
                // block parser a SECOND time over the whole document per open.
                precomputedBlocks: parsed.blocks,
                configuration: configuration
            )
            // scoped=nil is the point: the rebuild passes no scopedRanges, so
            // every token in the document is styled.

            // ROOT CAUSE (proven by a CPU sample of the 12.5–16s first-open hang):
            // per-key `addAttribute` creates a short-lived intermediate dict on every
            // call (the run's dict grows one key at a time), each interned into
            // Foundation's global WEAK NSAttributeDictionary table. Each intermediate
            // dies at the next add, leaving a weak tombstone, so the next insert triggers
            // `-[NSConcreteHashTable rehashAround:]` to compact — O(table) per insert,
            // quadratic overall, amplified by the app's large heap (expensive objc weak
            // ops). Coalescing to non-overlapping runs and writing each with ONE
            // `setAttributes` interns exactly one LIVE dict per run — no intermediates, no
            // tombstones, no rehash thrash. First open dropped from 16s to tens of ms.
            let runs = MarkdownStyler.flattenedRuns(ranges, base: baseAttrs,
                                                    documentLength: fullRange.length)
            for (range, attrs) in runs {
                built.setAttributes(attrs, range: range)
            }
        }

        // ONE live-storage mutation carries the whole styled document across. This is the
        // only edit that touches the layout-connected storage.
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributedString(built)
        textView.textStorage?.endEditing()


        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: configuration.theme
        )

        if let tlm = textView.textLayoutManager {
            if invalidateLayout {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // The re-entrant textViewDidChangeSelection was suppressed for this rebuild
        // (isRebuildingDocument), so replay the one selection-derived side effect nothing
        // else runs afterwards: spell/grammar/quote toggles for the loaded caret. Also seed
        // the selection bookkeeping the next real selection change diffs against, so it
        // starts from the loaded document instead of the previous one's stale caret. Raw
        // mode / active Writing Tools skip both, exactly as the suppressed handler's own
        // rawSourceMode / isWritingToolsActive early-returns would have.
        if let parsed = parsedForReplay, !isWritingToolsActive {
            let finalSelection = textView.selectedRange()
            updateAutocorrectSettings(
                textView,
                caretLocation: finalSelection.location,
                codeTokens: parsed.codeTokens,
                latexTokens: parsed.latexTokens,
                allTokens: parsed.tokens
            )
            previousActiveTokenIndices = activeTokenIndices
            previousCaretLocation = finalSelection.location
            previousSelectedRange = finalSelection
        }

        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func restyleTextView(
        _ textView: NSTextView,
        paragraphCandidates: [NSRange],
        tokens: [MarkdownToken]? = nil,
        classified: MarkdownStyler.ClassifiedStyleTokens? = nil,
        blocks: [Block]? = nil
    ) {
        // Raw mode: no restyling; typing keeps base attrs via the typing shim.
        guard !configuration.rawSourceMode else { return }
        let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )

        TextStylingService.restyle(
            textView: textView,
            layoutBridge: layoutBridge,
            paragraphCandidates: paragraphCandidates,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: textView.isEditable ? textView.selectedRange().location : -1,
            // Selection-revealed task syntax: this is the per-keystroke /
            // selection-change restyle path, so the styler needs the full
            // selected range here too (read-only suppresses it like the caret).
            selection: textView.isEditable ? textView.selectedRange() : nil,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: { [weak self] range in
                self?.wikiLinkID(for: range)
            },
            precomputedTokens: tokens,
            classified: classified,
            precomputedBlocks: blocks,
            configuration: configuration
        )
        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func parsedDocument(for text: String, edit: ParseEditDescriptor? = nil) -> ParsedDocument {
        let length = (text as NSString).length
        if let cachedParsedDocument, cachedParsedLength == length {
            // O(1) hit: nothing has edited the storage since the cached parse.
            if cachedParseGeneration == parseGeneration { return cachedParsedDocument }
            // Generation moved but the text may still be identical (e.g. an
            // attribute-only pass): confirm via NSString.isEqual (a byte
            // compare — the bridged Swift `==` walked 139k chars per keystroke).
            if let cachedParsedText, (cachedParsedText as NSString).isEqual(to: text) {
                cachedParseGeneration = parseGeneration
                return cachedParsedDocument
            }
        }

        let tokens = parseState.tokens(for: text, edit: edit, registry: cachedExtensionRegistry)
        let tClassify = DispatchTime.now().uptimeNanoseconds
        var codeTokens: [MarkdownToken] = []
        var latexTokens: [MarkdownToken] = []
        var blockLatexTokens: [MarkdownToken] = []
        var wikiLinkTokens: [MarkdownToken] = []
        var imageEmbedTokens: [MarkdownToken] = []
        var tableTokens: [MarkdownToken] = []
        var codeBlockTokensWithIndices: [(index: Int, token: MarkdownToken)] = []
        var inlineLatexIdx: [(index: Int, token: MarkdownToken)] = []
        var blockLatexIdx: [(index: Int, token: MarkdownToken)] = []
        var imageEmbedIdx: [(index: Int, token: MarkdownToken)] = []
        var imageLinkIdx: [(index: Int, token: MarkdownToken)] = []
        var tableIdx: [(index: Int, token: MarkdownToken)] = []

        codeTokens.reserveCapacity(tokens.count / 2)
        latexTokens.reserveCapacity(tokens.count / 4)
        blockLatexTokens.reserveCapacity(tokens.count / 4)
        wikiLinkTokens.reserveCapacity(tokens.count / 4)

        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .codeBlock, .inlineCode:
                codeTokens.append(token)
                if token.kind == .codeBlock {
                    codeBlockTokensWithIndices.append((index, token))
                }
            case .inlineLatex:
                latexTokens.append(token)
                inlineLatexIdx.append((index, token))
            case .blockLatex:
                blockLatexTokens.append(token)
                blockLatexIdx.append((index, token))
            case .wikiLink:
                wikiLinkTokens.append(token)
            case .imageEmbed:
                imageEmbedTokens.append(token)
                imageEmbedIdx.append((index, token))
            case .imageLink:
                imageLinkIdx.append((index, token))
            case .table:
                tableTokens.append(token)
                tableIdx.append((index, token))
            default:
                break
            }
        }

        parsedDocumentVersion &+= 1
        let parsed = ParsedDocument(
            source: text,
            tokens: tokens,
            blocks: parseState.currentBlocks,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            blockLatexTokens: blockLatexTokens,
            wikiLinkTokens: wikiLinkTokens,
            imageEmbedTokens: imageEmbedTokens,
            tableTokens: tableTokens,
            codeBlockTokensWithIndices: codeBlockTokensWithIndices,
            classified: MarkdownStyler.ClassifiedStyleTokens(
                inlineLatex: inlineLatexIdx, blockLatex: blockLatexIdx,
                imageEmbed: imageEmbedIdx, imageLink: imageLinkIdx,
                table: tableIdx, code: codeTokens),
            version: parsedDocumentVersion
        )
        cachedParsedText = text
        cachedParsedLength = length
        cachedParseGeneration = parseGeneration
        cachedParsedDocument = parsed
        PerfTrace.note {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - tClassify) / 1_000_000
            return "classify=\(String(format: "%.2f", ms))ms #tokens=\(tokens.count)"
        }
        return parsed
    }

    /// Memoized computeActiveTokenIndices — a pure function of
    /// (parsed.version, selection, suppressed) that otherwise runs up to
    /// three times per keystroke on identical inputs (pre-edit ask,
    /// selection change, textDidChange).
    func activeTokenIndices(parsed: ParsedDocument, selection: NSRange, in text: NSString, suppressed: Bool) -> Set<Int> {
        if let memo = activeTokenMemo, memo.version == parsed.version,
           memo.selection == selection, memo.suppressed == suppressed {
            return memo.result
        }
        let result = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selection, tokens: parsed.tokens, in: text, suppressed: suppressed)
        activeTokenMemo = (parsed.version, selection, suppressed, result)
        return result
    }

    func paragraphRanges(
        in text: NSString,
        intersecting editedRange: NSRange
    ) -> [NSRange] {
        guard text.length > 0 else { return [] }
        guard editedRange.location != NSNotFound else { return [] }

        var start = editedRange.location
        let end = min(NSMaxRange(editedRange), text.length)
        if start >= text.length {
            start = max(0, text.length - 1)
        }
        if end <= start {
            return [text.paragraphRange(for: NSRange(location: start, length: 0))]
        }

        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return ranges
    }

    func tokenRestyleParagraphs(
        in text: NSString,
        tokens: [MarkdownToken],
        currentActiveTokenIndices: Set<Int>,
        previousActiveTokenIndices: Set<Int>
    ) -> [NSRange] {
        var paragraphs: [NSRange] = []
        let indicesToStyle = currentActiveTokenIndices.union(previousActiveTokenIndices)

        for idx in indicesToStyle where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            paragraphs.append(text.paragraphRange(for: token.range))

            if token.kind == .codeBlock || token.kind == .blockLatex {
                for markerRange in token.markerRanges {
                    paragraphs.append(text.paragraphRange(for: markerRange))
                }
            }
        }

        return paragraphs
    }

    func restyleParagraphs(_ paragraphs: [NSRange], in textView: NSTextView) {
        let docText = textView.string      // one O(doc) bridge, reused below
        let parsed = parsedDocument(for: docText)
        let tokens = parsed.tokens
        let nsText = docText as NSString
        activeTokenIndices = activeTokenIndices(
            parsed: parsed,
            selection: textView.selectedRange(),
            in: nsText,
            suppressed: !textView.isEditable
        )
        restyleTextView(textView, paragraphCandidates: paragraphs, tokens: tokens,
                        classified: parsed.classified, blocks: parsed.blocks)
    }

    func applyInlineReplacement(_ request: InlineReplacementRequest, to textView: NSTextView) {
        lastAppliedInlineReplacementID = request.id

        let currentText = textView.string as NSString
        let range = request.selection.displayRange
        guard range.location != NSNotFound,
              range.location + range.length <= currentText.length else {
            return
        }

        // Image embeds and node links share one path: insert DISPLAY form `![[Name]]` / `[[Name]]`
        // with the opaque suffix on the `.wikiLinkID` side-channel (displayFragmentAndID handles `!`).
        let replacementInfo = WikiLinkService.displayFragmentAndID(from: request.storageFragment)
        let replacementDisplay = replacementInfo.display
        let linkID = replacementInfo.id

        let undoActionName = request.isImageEmbedMode ? "Insert Image Embed" : "Insert Link"
        textView.breakUndoCoalescing()

        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }

        guard textView.shouldChangeText(in: range, replacementString: replacementDisplay) else {
            return
        }

        textView.textStorage?.replaceCharacters(in: range, with: replacementDisplay)

        if let linkID, !linkID.isEmpty {
            let isImage = replacementDisplay.hasPrefix("![[")
            let openLen = isImage ? 3 : 2
            let contentLength = max(0, (replacementDisplay as NSString).length - (openLen + 2))
            if contentLength > 0 {
                let contentRange = NSRange(location: range.location + openLen, length: contentLength)
                textView.textStorage?.addAttribute(.wikiLinkID, value: linkID, range: contentRange)
            }
        }

        textView.didChangeText()
        textView.undoManager?.setActionName(undoActionName)
        textView.breakUndoCoalescing()

        let caretRange = WikiLinkService.caretRangeAfterReplacing(
            displayRange: range,
            with: request.storageFragment
        )
        let documentLength = (textView.string as NSString).length
        let clampedCaret = NSRange(location: min(max(caretRange.location, 0), documentLength), length: 0)

        if let bottomTextView = textView as? NativeTextView {
            bottomTextView.suppressAutoRevealOnce = true
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(clampedCaret)
    }

    /// Applies a storage-authoritative replacement in the live AppKit buffer.
    /// The binding is updated in this transaction so SwiftUI never sees stale
    /// source and rebuilds the editor (which briefly selects EOF).
    @discardableResult
    func applyTextReplacement(_ request: MarkdownTextReplacementRequest, to textView: NSTextView) -> MarkdownTextReplacementResult {
        func rejected(_ reason: MarkdownTextReplacementRejection) -> MarkdownTextReplacementResult {
            .rejected(id: request.id, editorId: request.editorId, documentId: request.documentId, reason: reason)
        }
        guard documentId == request.documentId else { return rejected(.wrongDocument) }
        guard editorId == request.editorId else { return rejected(.wrongEditor) }
        guard textView.isEditable else { return rejected(.notEditable) }
        guard !textView.hasMarkedText() else { return rejected(.markedText) }
        guard !isWritingToolsActive else { return rejected(.writingToolsActive) }

        let display = textView.string
        let displayNS = display as NSString
        guard isValid(request.displayRange, in: displayNS) else { return rejected(.invalidDisplayRange) }

        let currentState = WikiLinkService.makeStorageState(
            from: display,
            existingMetadata: wikiLinkMetadata,
            textStorage: textView.textStorage
        )
        guard currentState.storage == request.expectedStorage else { return rejected(.mismatchedStorage) }
        let proposedState: (display: String, metadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata])
        if configuration.rawSourceMode {
            proposedState = (request.resultingStorage, [:])
        } else {
            proposedState = WikiLinkService.makeDisplayState(from: request.resultingStorage) {
                self.configuration.services.wikiLinks.name(forID: $0)
            }
        }
        let proposedRange = NSRange(location: request.displayRange.location,
                                    length: (request.replacementDisplay as NSString).length)
        let expectedDisplay = displayNS.replacingCharacters(in: request.displayRange, with: request.replacementDisplay)
        guard proposedState.display == expectedDisplay else { return rejected(.mismatchedCoordinates) }
        let finalLength = (proposedState.display as NSString).length
        let selection = request.resultingDisplaySelection
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= finalLength else { return rejected(.invalidSelection) }

        // Prove the complete rendered proposal can round-trip to the exact
        // storage source before touching the live NSTextView. This keeps every
        // rejection atomic, including hidden-ID-only changes where the visible
        // replacement string is unchanged.
        let proposedTextStorage = NSTextStorage(string: proposedState.display)
        applyWikiLinkMetadata(proposedState.metadata, to: proposedTextStorage)
        let preflightState = WikiLinkService.makeStorageState(
            from: proposedState.display,
            existingMetadata: proposedState.metadata,
            textStorage: proposedTextStorage
        )
        guard preflightState.storage == request.resultingStorage else {
            return rejected(.mismatchedCoordinates)
        }

        textView.breakUndoCoalescing()
        isProgrammaticEdit = true
        requiresSynchronousBindingPublication = true
        defer {
            requiresSynchronousBindingPublication = false
            isProgrammaticEdit = false
        }
        let previousSelection = textView.selectedRange()
        let nativeUndoManager = textView.undoManager ?? undoManager(for: textView)
        let undoRegistrationWasEnabled = nativeUndoManager?.isUndoRegistrationEnabled == true
        if undoRegistrationWasEnabled { nativeUndoManager?.disableUndoRegistration() }
        guard textView.shouldChangeText(in: request.displayRange, replacementString: request.replacementDisplay) else {
            if undoRegistrationWasEnabled { nativeUndoManager?.enableUndoRegistration() }
            return rejected(.deniedByTextView)
        }

        textView.textStorage?.replaceCharacters(in: request.displayRange, with: request.replacementDisplay)
        // The full proposed rendering is authoritative, so an identical-display
        // reorder can still move distinct hidden wiki IDs correctly. Refreshing
        // the opaque attributes over the whole display also handles a token that
        // crosses the character-splice boundary without ever rewriting its text.
        if let textStorage = textView.textStorage {
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.removeAttribute(.wikiLinkID, range: fullRange)
            applyWikiLinkMetadata(proposedState.metadata, to: textStorage)
        }
        textView.didChangeText()
        if undoRegistrationWasEnabled { nativeUndoManager?.enableUndoRegistration() }
        textView.breakUndoCoalescing()

        if let nativeTextView = textView as? NativeTextView {
            nativeTextView.suppressAutoRevealOnce = true
        }
        textView.setSelectedRange(selection)

        // `textDidChange` remains the sole storage/binding publisher. The flag
        // above makes its normal publication synchronous for this transaction.
        let settledStorage = lastSyncedText

        // Register one model-aware inverse rather than relying on AppKit's
        // character-only receipt. Attribute-only structural changes (for
        // example swapping equal-looking wiki links with different IDs) need
        // their complete storage source restored by undo and redo as well.
        let oldDisplay = displayNS.substring(with: request.displayRange)
        let inverse = MarkdownTextReplacementRequest(
            editorId: request.editorId,
            documentId: request.documentId,
            expectedStorage: settledStorage,
            resultingStorage: request.expectedStorage,
            displayRange: proposedRange,
            replacementDisplay: oldDisplay,
            resultingDisplaySelection: previousSelection,
            undoActionName: request.undoActionName
        )
        nativeUndoManager?.registerUndo(withTarget: self) { coordinator in
            coordinator.applyTextReplacement(inverse, to: textView)
        }
        nativeUndoManager?.setActionName(request.undoActionName)
        return .applied(id: request.id, editorId: request.editorId, documentId: request.documentId, storage: settledStorage)
    }

    func handleTextReplacementNotification(_ notification: Notification) {
        guard let request = notification.userInfo?["request"] as? MarkdownTextReplacementRequest,
              request.editorId == editorId,
              !(notification.object is NSTextView)
                || notification.object as? NSTextView === textView
        else { return }
        let result: MarkdownTextReplacementResult
        if let textView {
            result = applyTextReplacement(request, to: textView)
        } else {
            result = .rejected(id: request.id, editorId: request.editorId, documentId: request.documentId, reason: .wrongDocument)
        }
        if let name = configuration.services.bus.textReplacementDidComplete {
            NotificationCenter.default.post(name: name, object: textView, userInfo: ["result": result])
        }
    }

    private func isValid(_ range: NSRange, in string: NSString) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && NSMaxRange(range) <= string.length
    }

    private func applyWikiLinkMetadata(
        _ metadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata],
        to textStorage: NSTextStorage
    ) {
        let display = textStorage.string as NSString
        for (key, link) in metadata {
            guard let id = link.id, !id.isEmpty else { continue }
            let tokenRange = NSRange(location: key.location, length: key.length)
            guard isValid(tokenRange, in: display) else { continue }
            let isImage = display.substring(with: tokenRange).hasPrefix("![[")
            let openLength = isImage ? 3 : 2
            let contentLength = max(0, tokenRange.length - openLength - 2)
            guard contentLength > 0 else { continue }
            textStorage.addAttribute(
                .wikiLinkID,
                value: id,
                range: NSRange(location: tokenRange.location + openLength, length: contentLength)
            )
        }
    }
}
