//
//  CodeBlockSelectionReceiptTests.swift
//  MarkdownEngineTests
//
//  Code-block overlay receipts bind copy controls to the exact native source
//  that produced them. This prevents a delayed overlay from another document
//  (or another location with identical code) from being accepted by hosts.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Code-block selection receipts")
struct CodeBlockSelectionReceiptTests {
    private func makeEditor(
        documentId: String,
        source: String
    ) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(source), fontName: "SF Pro", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.documentId = documentId

        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.string = source
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        if let layoutManager = textView.textLayoutManager {
            coordinator.layoutBridge = LayoutBridge(layoutManager)
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        return (coordinator, textView)
    }

    @Test("selection construction remains source compatible")
    func selectionConstructionRemainsSourceCompatible() {
        let legacy = CodeBlockSelection(
            id: 1, rect: .zero, language: "swift", code: "let x = 1"
        )
        #expect(legacy.sourceRange == nil)

        let ranged = CodeBlockSelection(
            id: 2, rect: .zero, language: nil, code: "x",
            sourceRange: NSRange(location: 3, length: 9)
        )
        #expect(ranged.sourceRange == NSRange(location: 3, length: 9))
    }

    @Test("receipt carries exact fenced source range and parse context")
    func receiptCarriesExactRangeAndContext() throws {
        let source = "before\n```swift\nlet same = 1\n```\nafter\n"
        let (coordinator, textView) = makeEditor(documentId: "note-a", source: source)
        var updates: [CodeBlockSelectionUpdate] = []
        var legacy: [[CodeBlockSelection]] = []
        coordinator.onCodeBlockSelectionUpdate = { updates.append($0) }
        coordinator.onCodeBlockSelectionChange = { legacy.append($0) }

        let parsed = coordinator.parsedDocument(for: source)
        coordinator.updateCodeBlockSelection(textView: textView, parsed: parsed)

        let update = try #require(updates.last)
        let selection = try #require(update.selections.first)
        let expectedRange = (source as NSString).range(of: "```swift\nlet same = 1\n```")
        #expect(update.documentId == "note-a")
        #expect(update.editorId == "default")
        #expect(update.editorSessionId == "default")
        #expect(update.source == source)
        #expect(update.parseVersion == parsed.version)
        #expect(selection.sourceRange == expectedRange)
        #expect(legacy.last?.map(\.id) == update.selections.map(\.id))
    }

    @Test("no-parse refresh rejects same code from another location or document")
    func staleRefreshRejectsSameContentAtAnotherLocationOrDocument() throws {
        let oldSource = "prefix\n```swift\nlet same = 1\n```\n"
        let newSource = "longer prefix moves it\n```swift\nlet same = 1\n```\n"
        let (coordinator, textView) = makeEditor(documentId: "note-a", source: oldSource)
        var updates: [CodeBlockSelectionUpdate] = []
        var legacy: [[CodeBlockSelection]] = []
        coordinator.onCodeBlockSelectionUpdate = { updates.append($0) }
        coordinator.onCodeBlockSelectionChange = { legacy.append($0) }

        coordinator.updateCodeBlockSelection(
            textView: textView,
            parsed: coordinator.parsedDocument(for: oldSource)
        )
        #expect(coordinator.cachedCodeBlockTokenCache != nil)

        // Simulate a queued no-parse refresh after a programmatic native
        // source swap. The production rebuild suppresses its re-entrant
        // selection callback; detaching the test delegate gives this direct
        // fixture the same cache boundary.
        textView.delegate = nil
        textView.string = newSource
        textView.delegate = coordinator
        coordinator.updateCodeBlockSelection(textView: textView)

        let staleSourceReset = try #require(updates.last)
        #expect(staleSourceReset.documentId == "note-a")
        #expect(staleSourceReset.source == newSource)
        #expect(staleSourceReset.selections.isEmpty)
        #expect(legacy.last?.isEmpty == true)
        #expect(coordinator.cachedCodeBlockTokenCache == nil)

        // Re-prime the cache, then switch identity while the code is identical.
        coordinator.updateCodeBlockSelection(
            textView: textView,
            parsed: coordinator.parsedDocument(for: newSource)
        )
        coordinator.documentId = "note-b"
        coordinator.updateCodeBlockSelection(textView: textView)

        let staleDocumentReset = try #require(updates.last)
        #expect(staleDocumentReset.documentId == "note-b")
        #expect(staleDocumentReset.source == newSource)
        #expect(staleDocumentReset.selections.isEmpty)
        #expect(legacy.last?.isEmpty == true)
        #expect(coordinator.cachedCodeBlockTokenCache == nil)
    }

    @Test("document-switch invalidation clears cache and overlays synchronously")
    func documentSwitchInvalidationClearsCacheAndOverlaysSynchronously() throws {
        let source = "```\nlet value = 1\n```\n"
        let (coordinator, textView) = makeEditor(documentId: "outgoing", source: source)
        var updates: [CodeBlockSelectionUpdate] = []
        var legacy: [[CodeBlockSelection]] = []
        coordinator.onCodeBlockSelectionUpdate = { updates.append($0) }
        coordinator.onCodeBlockSelectionChange = { legacy.append($0) }
        coordinator.updateCodeBlockSelection(
            textView: textView,
            parsed: coordinator.parsedDocument(for: source)
        )
        #expect(coordinator.cachedCodeBlockTokenCache != nil)

        coordinator.invalidateCodeBlockSelectionCache()

        let reset = try #require(updates.last)
        #expect(reset.documentId == "outgoing")
        #expect(reset.source == source)
        #expect(reset.selections.isEmpty)
        #expect(legacy.last?.isEmpty == true)
        #expect(coordinator.cachedCodeBlockTokenCache == nil)
    }

    @Test("rebuild after an identical-source document switch mints a fresh receipt")
    func rebuildAfterDocumentSwitchMintsFreshReceipt() throws {
        let source = "```swift\nlet same = 1\n```\n"
        let (coordinator, textView) = makeEditor(documentId: "note-a", source: source)
        var updates: [CodeBlockSelectionUpdate] = []
        coordinator.onCodeBlockSelectionUpdate = { updates.append($0) }

        let oldParsed = coordinator.parsedDocument(for: source)
        coordinator.updateCodeBlockSelection(textView: textView, parsed: oldParsed)

        coordinator.invalidateCodeBlockSelectionCache()
        coordinator.documentId = "note-b"
        coordinator.cachedParsedDocument = nil
        coordinator.cachedParsedText = nil
        coordinator.cachedParsedLength = -1
        coordinator.cachedParseGeneration = .max
        coordinator.activeTokenMemo = nil
        coordinator.rebuildTextStorageAndStyle(textView, from: source, invalidateLayout: true)
        let incomingParsed = coordinator.parsedDocument(for: textView.string)
        coordinator.updateCodeBlockSelection(textView: textView, parsed: incomingParsed)

        let receipt = try #require(updates.last)
        #expect(receipt.documentId == "note-b")
        #expect(receipt.source == source)
        #expect(receipt.parseVersion > oldParsed.version)
        #expect(receipt.selections.first?.sourceRange == (source as NSString).range(of: "```swift\nlet same = 1\n```"))
    }

    @Test("raw source mode publishes an empty receipt")
    func rawSourceModePublishesEmptyReceipt() throws {
        let source = "```\nlet value = 1\n```\n"
        let (coordinator, textView) = makeEditor(documentId: "note-a", source: source)
        var updates: [CodeBlockSelectionUpdate] = []
        var legacy: [[CodeBlockSelection]] = []
        coordinator.onCodeBlockSelectionUpdate = { updates.append($0) }
        coordinator.onCodeBlockSelectionChange = { legacy.append($0) }
        coordinator.configuration.rawSourceMode = true

        coordinator.updateCodeBlockSelection(
            textView: textView,
            parsed: coordinator.parsedDocument(for: source)
        )

        let receipt = try #require(updates.last)
        #expect(receipt.selections.isEmpty)
        #expect(legacy.last?.isEmpty == true)
        #expect(coordinator.cachedCodeBlockTokenCache == nil)
    }

    @Test("same-length source edits advance the receipt version")
    func sameLengthSourceEditAdvancesReceiptVersion() throws {
        let oldSource = "```swift\nlet value = 1\n```\n"
        let newSource = "```swift\nlet value = 2\n```\n"
        let (coordinator, textView) = makeEditor(documentId: "note-a", source: oldSource)
        var updates: [CodeBlockSelectionUpdate] = []
        coordinator.onCodeBlockSelectionUpdate = { updates.append($0) }

        let oldParsed = coordinator.parsedDocument(for: oldSource)
        coordinator.updateCodeBlockSelection(textView: textView, parsed: oldParsed)

        let editRange = (oldSource as NSString).range(of: "1")
        textView.insertText("2", replacementRange: editRange)
        #expect(textView.string == newSource)

        let newParsed = coordinator.parsedDocument(for: newSource)
        coordinator.updateCodeBlockSelection(textView: textView, parsed: newParsed)
        let current = try #require(updates.last)
        #expect(current.source == newSource)
        #expect(current.parseVersion > oldParsed.version)
        #expect(current.selections.first?.code == "let value = 2\n")

        // A queued callback still holding the prior parse fails closed and
        // remains older than the current receipt, so a host can ignore it.
        coordinator.updateCodeBlockSelection(textView: textView, parsed: oldParsed)
        let delayed = try #require(updates.last)
        #expect(delayed.source == newSource)
        #expect(delayed.parseVersion == oldParsed.version)
        #expect(delayed.parseVersion < current.parseVersion)
        #expect(delayed.selections.isEmpty)
    }

    @Test("grammar invalidation clears a previously published receipt")
    func grammarInvalidationClearsPreviouslyPublishedReceipt() throws {
        let source = "```swift\nlet value = 1\n```\n"
        let (coordinator, textView) = makeEditor(documentId: "note-a", source: source)
        var updates: [CodeBlockSelectionUpdate] = []
        coordinator.onCodeBlockSelectionUpdate = { updates.append($0) }
        coordinator.updateCodeBlockSelection(
            textView: textView,
            parsed: coordinator.parsedDocument(for: source)
        )
        #expect(updates.last?.selections.isEmpty == false)

        coordinator.invalidateCodeBlockSelectionCache()

        let reset = try #require(updates.last)
        #expect(reset.documentId == "note-a")
        #expect(reset.source == source)
        #expect(reset.selections.isEmpty)
        #expect(coordinator.cachedCodeBlockTokenCache == nil)
    }
}
