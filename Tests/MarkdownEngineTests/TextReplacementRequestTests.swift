//
//  MarkdownTextReplacementRequestTests.swift
//  MarkdownEngineTests
//
//  Structural edits must mutate the native buffer, not round-trip through a
//  SwiftUI rebuild (which transiently puts AppKit's selection at EOF).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
private final class HostedReplacementModel: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}

private struct HostedReplacementEditor: View {
    @ObservedObject var model: HostedReplacementModel
    let requestNotification: Notification.Name
    let completionNotification: Notification.Name

    var body: some View {
        NativeTextViewWrapper(
            text: $model.text,
            configuration: configuration,
            fontName: "SF Pro",
            fontSize: 14,
            documentId: "note-a",
            editorId: "hosted-editor"
        )
    }

    private var configuration: MarkdownEditorConfiguration {
        var value = MarkdownEditorConfiguration.default
        value.services.bus = MarkdownEditorBus(
            applyTextReplacementRequest: requestNotification,
            textReplacementDidComplete: completionNotification
        )
        return value
    }
}

@MainActor
@Suite("Synchronous Markdown text replacement requests")
struct MarkdownTextReplacementRequestTests {
    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let match = firstTextView(in: subview) { return match }
        }
        return nil
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func makeEditor(storage: String, documentId: String = "note-a") -> (NativeTextViewCoordinator, NativeTextView, Binding<String>, Notification.Name) {
        _ = NSApplication.shared
        var published = storage
        let binding = Binding<String>(get: { published }, set: { published = $0 })
        let notification = Notification.Name("MarkdownTextReplacementRequestTests.\(UUID().uuidString)")
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.bus = MarkdownEditorBus(applyTextReplacementRequest: notification)
        let coordinator = NativeTextViewCoordinator(text: binding, fontName: "SF Pro", fontSize: 14,
                                                    isWikiLinkActive: .constant(false), onLinkClick: nil,
                                                    onInlineSelectionChange: nil)
        coordinator.configuration = configuration
        coordinator.documentId = documentId
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: storage)
        return (coordinator, textView, binding, notification)
    }

    private func request(storage: String, display: String, replacement: String,
                         selection: NSRange, documentId: String = "note-a") -> MarkdownTextReplacementRequest {
        MarkdownTextReplacementRequest(documentId: documentId, expectedStorage: storage,
                               resultingStorage: replacement,
                               displayRange: NSRange(location: 0, length: (display as NSString).length),
                               replacementDisplay: WikiLinkService.makeDisplayState(from: replacement).display,
                               resultingDisplaySelection: selection, undoActionName: "Move Line")
    }

    @Test("moves a plain block in native storage and publishes without a rebuild")
    func plainMoveSynchronizesBinding() {
        let source = "one\ntwo\nthree\n"
        let replacement = "two\none\nthree\n"
        let (coordinator, textView, binding, notification) = makeEditor(storage: source)
        let change = request(storage: source, display: textView.string, replacement: replacement,
                             selection: NSRange(location: 0, length: 0))

        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["request": change])

        #expect(textView.string == replacement)
        #expect(binding.wrappedValue == replacement)
        #expect(coordinator.lastSyncedText == replacement)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test("the SwiftUI wrapper update keeps the requested caret instead of rebuilding to EOF")
    func wrapperUpdatePreservesCaret() throws {
        let source = "one\ntwo\nthree\nfour\n"
        let replacement = "two\none\nthree\nfour\n"
        let requestNotification = Notification.Name("MarkdownTextReplacementRequestTests.hosted.request.\(UUID().uuidString)")
        let completionNotification = Notification.Name("MarkdownTextReplacementRequestTests.hosted.complete.\(UUID().uuidString)")
        let model = HostedReplacementModel(text: source)
        let host = NSHostingView(rootView: HostedReplacementEditor(
            model: model,
            requestNotification: requestNotification,
            completionNotification: completionNotification
        ))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        drainMainRunLoop()

        let textView = try #require(firstTextView(in: host))
        let target = NSRange(location: 4, length: 0)
        let change = MarkdownTextReplacementRequest(
            editorId: "hosted-editor",
            documentId: "note-a",
            expectedStorage: source,
            resultingStorage: replacement,
            displayRange: NSRange(location: 0, length: (source as NSString).length),
            replacementDisplay: replacement,
            resultingDisplaySelection: target,
            undoActionName: "Move Line"
        )

        NotificationCenter.default.post(
            name: requestNotification,
            object: nil,
            userInfo: ["request": change]
        )
        #expect(model.text == replacement)
        #expect(textView.selectedRange() == target)

        // Publishing the binding schedules NativeTextViewWrapper.updateNSView.
        // Exercise that pass and a subsequent layout turn: a rebuild here used
        // to park the native selection at the end of the document.
        drainMainRunLoop()
        host.layoutSubtreeIfNeeded()
        drainMainRunLoop()
        #expect(textView.string == replacement)
        #expect(textView.selectedRange() == target)
        _ = window
    }

    @Test("preserves every wiki link ID through a multi-link move")
    func multipleWikiLinksRoundTrip() {
        let source = "first [[Alpha|ID-A]]\nsecond [[Beta|ID-B]]\n"
        let replacement = "second [[Beta|ID-B]]\nfirst [[Alpha|ID-A]]\n"
        let (_, textView, binding, notification) = makeEditor(storage: source)
        let change = request(storage: source, display: textView.string, replacement: replacement,
                             selection: NSRange(location: 0, length: 0))

        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["request": change])

        #expect(textView.string == "second [[Beta]]\nfirst [[Alpha]]\n")
        #expect(binding.wrappedValue == replacement)
        let beta = (textView.string as NSString).range(of: "Beta")
        let alpha = (textView.string as NSString).range(of: "Alpha")
        #expect(textView.textStorage?.attribute(.wikiLinkID, at: beta.location, effectiveRange: nil) as? String == "ID-B")
        #expect(textView.textStorage?.attribute(.wikiLinkID, at: alpha.location, effectiveRange: nil) as? String == "ID-A")
    }

    @Test("reorders identical rendered links by their hidden IDs")
    func sameDisplayDifferentIDReorder() {
        let source = "[[Same|ID-1]] [[Same|ID-2]]\n"
        let replacement = "[[Same|ID-2]] [[Same|ID-1]]\n"
        let (_, textView, binding, notification) = makeEditor(storage: source)
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["request": request(storage: source, display: textView.string, replacement: replacement, selection: .init(location: 0, length: 0))])
        #expect(binding.wrappedValue == replacement)
        #expect(textView.textStorage?.attribute(.wikiLinkID, at: 2, effectiveRange: nil) as? String == "ID-2")
    }

    @Test("only the targeted editor acknowledges a request")
    func acknowledgementAndEditorTargeting() {
        let source = "one\n"
        let (coordinator, textView, _, _) = makeEditor(storage: source)
        coordinator.editorId = "editor-a"
        let completion = Notification.Name("MarkdownTextReplacementRequestTests.complete.\(UUID().uuidString)")
        coordinator.configuration.services.bus = MarkdownEditorBus(textReplacementDidComplete: completion)
        var result: MarkdownTextReplacementResult?
        let observer = NotificationCenter.default.addObserver(forName: completion, object: nil, queue: nil) { note in
            result = note.userInfo?["result"] as? MarkdownTextReplacementResult
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let request = MarkdownTextReplacementRequest(editorId: "editor-b", documentId: "note-a", expectedStorage: source,
                                                      resultingStorage: "two\n", displayRange: .init(location: 0, length: 4),
                                                      replacementDisplay: "two\n", resultingDisplaySelection: .init(location: 0, length: 0),
                                                      undoActionName: "Move Line")
        coordinator.handleTextReplacementNotification(Notification(name: Notification.Name("ignored"), object: nil, userInfo: ["request": request]))
        #expect(textView.string == source)
        #expect(result == nil)

        coordinator.editorId = "editor-b"
        coordinator.handleTextReplacementNotification(Notification(name: Notification.Name("ignored"), object: nil, userInfo: ["request": request]))
        if case .applied(_, "editor-b", "note-a", "two\n") = result {} else {
            Issue.record("expected one acknowledgement from the targeted editor")
        }
    }

    @Test("uses one native undo step and restores the requested selection")
    func undoAndSelection() {
        let source = "one\ntwo\n"
        let replacement = "two\none\n"
        let (coordinator, textView, _, notification) = makeEditor(storage: source)
        let selection = NSRange(location: 4, length: 0)
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["request": request(storage: source, display: textView.string, replacement: replacement, selection: selection)])

        #expect(textView.selectedRange() == selection)
        #expect(coordinator.undoManager(for: textView)?.canUndo == true)
        coordinator.undoManager(for: textView)?.undo()
        #expect(textView.string == source)
    }

    @Test("undo and redo restore hidden wiki identities and the storage binding")
    func undoRedoHiddenIdentity() {
        let source = "[[Same|ID-1]] [[Same|ID-2]]\n"
        let replacement = "[[Same|ID-2]] [[Same|ID-1]]\n"
        let (coordinator, textView, binding, notification) = makeEditor(storage: source)
        let manager = coordinator.undoManager(for: textView)

        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: ["request": request(
                storage: source,
                display: textView.string,
                replacement: replacement,
                selection: NSRange(location: 0, length: 0)
            )]
        )
        #expect(binding.wrappedValue == replacement)

        manager?.undo()
        #expect(binding.wrappedValue == source)
        #expect(textView.textStorage?.attribute(.wikiLinkID, at: 2, effectiveRange: nil) as? String == "ID-1")

        manager?.redo()
        #expect(binding.wrappedValue == replacement)
        #expect(textView.textStorage?.attribute(.wikiLinkID, at: 2, effectiveRange: nil) as? String == "ID-2")
    }

    @Test("raw source mode applies and publishes the exact storage splice")
    func rawSourceMode() {
        let source = "one\ntwo\n"
        let replacement = "two\none\n"
        let (coordinator, textView, binding, _) = makeEditor(storage: source)
        coordinator.configuration.rawSourceMode = true
        textView.configuration.rawSourceMode = true

        let result = coordinator.applyTextReplacement(
            request(
                storage: source,
                display: source,
                replacement: replacement,
                selection: NSRange(location: 0, length: 0)
            ),
            to: textView
        )

        if case .applied(_, _, _, replacement) = result {
            #expect(binding.wrappedValue == replacement)
            #expect(textView.string == replacement)
        } else {
            Issue.record("expected raw replacement to apply")
        }
    }

    @Test("rejects stale and wrong-document requests")
    func rejectsUnsafeRequests() {
        let source = "one\ntwo\n"
        let (_, textView, binding, notification) = makeEditor(storage: source)
        let stale = request(storage: "other\n", display: textView.string, replacement: "two\none\n",
                            selection: NSRange(location: 0, length: 0))
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["request": stale])
        #expect(textView.string == source)
        let wrongDocument = request(storage: source, display: textView.string, replacement: "two\none\n",
                                    selection: NSRange(location: 0, length: 0), documentId: "note-b")
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["request": wrongDocument])
        #expect(textView.string == source)
        #expect(binding.wrappedValue == source)
    }

    @Test("rejects invalid selection, read-only state, Writing Tools, and inconsistent display coordinates")
    func rejectsUnsafeEditorStateAndCoordinates() {
        let source = "[[Alpha|ID-A]]\n"
        let (coordinator, textView, _, _) = makeEditor(storage: source)
        let invalidSelection = MarkdownTextReplacementRequest(
            documentId: "note-a", expectedStorage: source,
            resultingStorage: source, displayRange: NSRange(location: 0, length: (textView.string as NSString).length),
            replacementDisplay: textView.string, resultingDisplaySelection: NSRange(location: 999, length: 0),
            undoActionName: "Move Line"
        )
        if case .rejected(_, _, _, .invalidSelection) = coordinator.applyTextReplacement(invalidSelection, to: textView) {} else {
            Issue.record("expected invalid selection rejection")
        }
        textView.isEditable = false
        if case .rejected(_, _, _, .notEditable) = coordinator.applyTextReplacement(request(storage: source, display: textView.string, replacement: source, selection: .init(location: 0, length: 0)), to: textView) {} else {
            Issue.record("expected read-only rejection")
        }
        textView.isEditable = true
        coordinator.isWritingToolsActive = true
        if case .rejected(_, _, _, .writingToolsActive) = coordinator.applyTextReplacement(request(storage: source, display: textView.string, replacement: source, selection: .init(location: 0, length: 0)), to: textView) {} else {
            Issue.record("expected Writing Tools rejection")
        }
        coordinator.isWritingToolsActive = false
        let partial = MarkdownTextReplacementRequest(documentId: "note-a", expectedStorage: source,
                                                      resultingStorage: "[[Beta|ID-A]]\n",
                                                      displayRange: NSRange(location: 3, length: 3),
                                                      replacementDisplay: "Beta",
                                                      resultingDisplaySelection: NSRange(location: 0, length: 0),
                                                      undoActionName: "Move Line")
        if case .rejected(_, _, _, .mismatchedCoordinates) = coordinator.applyTextReplacement(partial, to: textView) {} else {
            Issue.record("expected invalid partial coordinate rejection")
        }
    }
}
