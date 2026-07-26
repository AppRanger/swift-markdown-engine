//
//  AttrApplyBench.swift
//  MarkdownEngineTests
//
//  TEMP: measures the old per-key `addAttribute` loop against `flattenedRuns` on
//  the real 346k-char note, through a real NSTextContentStorage/NSTextLayoutManager
//  stack (the quadratic only shows up on storage that TextKit 2 observes).
//  Gated on MD_BENCH=1 — the naive path takes ~20s.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

private func perfNotePath() -> String {
    ("~/Library/Containers/com.nvm.nodes/Data/Documents/MarkdownFiles/"
     + "730522FC-C1BF-4A64-ACCA-4DCCF89A11AF.md" as NSString).expandingTildeInPath
}

/// Mirrors `SwiftMathBridge`: one distinct `NSImage` per distinct formula, cached.
/// Faithful on purpose — a single shared image would hide any per-value cost the
/// storage pays when it compares attribute dictionaries.
private final class StubLatexRenderer: LatexRenderer, @unchecked Sendable {
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        lock.lock(); defer { lock.unlock() }
        let image: NSImage
        if let cached = cache[latex] {
            image = cached
        } else {
            let made = NSImage(size: CGSize(width: 40, height: 18))
            made.lockFocus()
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 40, height: 18).fill()
            made.unlockFocus()
            cache[latex] = made
            image = made
        }
        return LatexRenderResult(image: image, size: CGSize(width: 40, height: 18), baselineOffset: 0)
    }
}

/// The isolated storage bench below could not reproduce the app's 213µs/call, so
/// this one drives the REAL load path — `NativeTextView`'s own TextKit 2 stack, the
/// layout delegate, the layout bridge, spell checking — through
/// `rebuildTextStorageAndStyle`, and lets OpenTrace print the same trace the app
/// prints. Anything that still doesn't reproduce here is caused by something only
/// the running app has (window, viewport controller, live scroll view).
/// Stands in for `HighlighterSwiftBridge`. What matters is not the colors but the
/// SHAPE it produces downstream: `styleCodeBlock` copies one styled range per
/// distinct foreground run, so a real highlighter adds thousands of tiny ranges —
/// the ~23k the app's trace has and the no-op harness does not.
private struct StubSyntaxHighlighter: SyntaxHighlighter {
    /// Token width in characters; smaller means more ranges.
    let tokenWidth: Int
    func codeFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    func backgroundColor() -> NSColor { NSColor.textBackgroundColor.withAlphaComponent(0) }
    var appearanceDidChangeNotification: Notification.Name? { nil }
    func highlight(code: String, language: String?) -> NSAttributedString? {
        let out = NSMutableAttributedString(string: code)
        let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemPurple]
        let length = (code as NSString).length
        var location = 0
        var i = 0
        while location < length {
            let span = min(tokenWidth, length - location)
            out.addAttribute(.foregroundColor, value: colors[i % colors.count],
                             range: NSRange(location: location, length: span))
            location += span
            i += 1
        }
        return out
    }
}

@Suite("rebuild repro", .enabled(if: ProcessInfo.processInfo.environment["MD_BENCH"] == "1"))
@MainActor
struct RebuildReproBench {

    @Test("rebuildTextStorageAndStyle on the real 346k note")
    func rebuild() throws {
        _ = NSApplication.shared
        let text = try String(contentsOfFile: perfNotePath(), encoding: .utf8)

        // MD_WINDOW=1 puts the text view in a real on-screen window inside a scroll
        // view, as key + first responder. That is the last structural difference to
        // the app: only then does NSTextViewportLayoutController actually render, so
        // only then can an attribute edit provoke viewport work.
        let windowed = ProcessInfo.processInfo.environment["MD_WINDOW"] == "1"
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        guard let container = textView.textContainer,
              let tlm = textView.textLayoutManager else {
            Issue.record("no TextKit 2 stack"); return
        }
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false

        var config = MarkdownEditorConfiguration.default
        config.services.latex = StubLatexRenderer()
        let tokenWidth = Int(ProcessInfo.processInfo.environment["MD_TOKEN_WIDTH"] ?? "") ?? 3
        config.services.syntaxHighlighter = StubSyntaxHighlighter(tokenWidth: tokenWidth)

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = layoutDelegate
        textView.configuration = config
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.isVerticallyResizable = true
        textView.allowsUndo = true
        // Mirror makeNSView exactly — these were missing and are the remaining
        // structural difference to the app. Autocorrect and Writing Tools both
        // observe the text storage and reach XPC services.
        textView.isContinuousSpellCheckingEnabled = config.spellChecking.continuousSpellChecking
        textView.isGrammarCheckingEnabled = config.spellChecking.grammarChecking
        textView.isAutomaticSpellingCorrectionEnabled = config.spellChecking.automaticSpellingCorrection
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.postsFrameChangedNotifications = true
        if #available(macOS 15.1, *) {
            textView.writingToolsBehavior = .complete
        }

        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro Text", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        coordinator.configuration = config
        coordinator.layoutDelegate = layoutDelegate
        coordinator.layoutBridge = LayoutBridge(tlm)
        textView.layoutBridge = coordinator.layoutBridge
        textView.delegate = coordinator

        var window: NSWindow?
        if windowed {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
            scrollView.hasVerticalScroller = true
            let host = NativeTextViewContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
            host.textView = textView
            host.addSubview(textView)
            scrollView.documentView = host
            textView.isVerticallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = scrollView
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(textView)
            win.displayIfNeeded()
            window = win
        }

        // MD_TK1=1 forces AppKit's TextKit 1 compatibility layout manager onto the
        // same storage. If that reproduces the app's profile, the app is silently in
        // compatibility mode and every attribute edit is paying glyph/layout
        // invalidation on top of TextKit 2.
        if ProcessInfo.processInfo.environment["MD_TK1"] == "1" {
            let legacy = NSLayoutManager()
            textView.textStorage?.addLayoutManager(legacy)
            let legacyContainer = NSTextContainer(size: CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
            legacy.addTextContainer(legacyContainer)
            legacy.ensureLayout(for: legacyContainer)
        }
        OpenTrace.mark("ENG-8h* env", "tk1Managers=\(textView.textStorage?.layoutManagers.count ?? -1) "
                       + "hasTLM=\(textView.textLayoutManager != nil)")

        OpenTrace.beginOpen("REPRO windowed=\(windowed) chars=\((text as NSString).length)")
        coordinator.rebuildTextStorageAndStyle(textView, from: text, invalidateLayout: true)
        OpenTrace.markInteractive()
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))

        window?.orderOut(nil)

        // CONTROL — the loop `flattenedRuns` replaced, run against this same LIVE,
        // fully laid-out text view. Without it the comparison is between two
        // different environments and proves nothing.
        guard let storage = textView.textStorage, let bridge = coordinator.layoutBridge else {
            Issue.record("no storage"); return
        }
        let display = textView.string
        let length = (display as NSString).length
        let ranges = MarkdownStyler.styleAttributes(
            text: display, fontName: "SF Pro Text", fontSize: 16,
            layoutBridge: bridge, caretLocation: -1, activeTokenIndices: [], configuration: config
        )
        func ms(_ body: () -> Void) -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        }
        var calls = 0
        let oldMs = ms {
            storage.beginEditing()
            for (range, attrs) in ranges {
                for (key, value) in attrs {
                    storage.addAttribute(key, value: value, range: range)
                    calls += 1
                }
            }
            storage.endEditing()
        }
        var runs: [StyledRange] = []
        let newMs = ms {
            storage.beginEditing()
            runs = MarkdownStyler.flattenedRuns(ranges, base: [:], documentLength: length)
            for (range, attrs) in runs { storage.setAttributes(attrs, range: range) }
            storage.endEditing()
        }
        print(String(format: """
           ── control on the LIVE text view ──
              OLD addAttribute loop : %8.1f ms  (%d calls, %.1f µs/call)
              NEW flattenedRuns     : %8.1f ms  (%d runs)
        """, oldMs, calls, oldMs * 1000 / Double(calls), newMs, runs.count))
    }
}

@Suite("attrApply bench", .enabled(if: ProcessInfo.processInfo.environment["MD_BENCH"] == "1"))
struct AttrApplyBench {

    /// `laidOut: true` reproduces the app's ordering — `textView.string =` forces a
    /// full-document layout (via the selection delegate) BEFORE the styling is
    /// applied, so the content storage carries a full cache of text elements while
    /// the attribute writes run.
    private func makeStorage(_ text: String, laidOut: Bool) -> NSTextStorage {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        layout.textContainer = NSTextContainer(size: CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        let storage = content.textStorage ?? NSTextStorage()
        storage.setAttributedString(NSAttributedString(string: text))
        if laidOut { layout.ensureLayout(for: layout.documentRange) }
        return storage
    }

    @Test("old loop vs flattened runs, real document")
    func compare() throws {
        // The table styler reads NSApp.effectiveAppearance (implicitly unwrapped).
        _ = NSApplication.shared
        let path = ("~/Library/Containers/com.nvm.nodes/Data/Documents/MarkdownFiles/"
                    + "730522FC-C1BF-4A64-ACCA-4DCCF89A11AF.md") as NSString
        let text = try String(contentsOfFile: path.expandingTildeInPath, encoding: .utf8)
        let length = (text as NSString).length

        let font = NSFont.systemFont(ofSize: 16)
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: NSParagraphStyle.default
        ]
        let full = NSRange(location: 0, length: length)

        var config = MarkdownEditorConfiguration.default
        config.services.latex = StubLatexRenderer()
        let ranges = MarkdownStyler.styleAttributes(
            text: text, fontName: font.fontName, fontSize: 16,
            caretLocation: -1, activeTokenIndices: [], configuration: config
        )

        // Which attribute key is expensive? The old loop's cost is per (range, key)
        // pair, so a per-key split names the culprit instead of guessing.
        var perKey: [NSAttributedString.Key: (ms: Double, n: Int)] = [:]

        func ms(_ body: () -> Void) -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        }

        var calls = 0
        func runOld(laidOut: Bool, countKeys: Bool) -> (ms: Double, storage: NSTextStorage) {
            let storage = makeStorage(text, laidOut: laidOut)
            calls = 0
            let elapsed = ms {
                storage.beginEditing()
                storage.setAttributes(base, range: full)
                for (range, attrs) in ranges {
                    for (key, value) in attrs {
                        if countKeys {
                            let t0 = DispatchTime.now().uptimeNanoseconds
                            storage.addAttribute(key, value: value, range: range)
                            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                            let prior = perKey[key] ?? (0, 0)
                            perKey[key] = (prior.ms + dt, prior.n + 1)
                        } else {
                            storage.addAttribute(key, value: value, range: range)
                        }
                        calls += 1
                    }
                }
                storage.endEditing()
            }
            return (elapsed, storage)
        }

        var runs: [StyledRange] = []
        var flattenMs = 0.0
        func runNew(laidOut: Bool) -> (ms: Double, storage: NSTextStorage) {
            let storage = makeStorage(text, laidOut: laidOut)
            let elapsed = ms {
                storage.beginEditing()
                storage.setAttributes(base, range: full)
                flattenMs = ms {
                    runs = MarkdownStyler.flattenedRuns(ranges, base: base, documentLength: length)
                }
                for (range, attrs) in runs {
                    storage.setAttributes(attrs, range: range)
                }
                storage.endEditing()
            }
            return (elapsed, storage)
        }

        let oldCold = runOld(laidOut: false, countKeys: true)
        let callCount = calls
        let newCold = runNew(laidOut: false)
        let oldWarm = runOld(laidOut: true, countKeys: false)
        let newWarm = runNew(laidOut: true)

        print(String(format: """

        ── attrApply bench ── chars=%d ranges=%d calls=%d runs=%d
                                     layout COLD        layout WARM (as in the app)
           OLD  addAttribute loop : %8.1f ms       %10.1f ms   (%.1f vs %.1f µs/call)
           NEW  flattenedRuns     : %8.1f ms       %10.1f ms   (flatten %.1f ms)
        """, length, ranges.count, callCount, runs.count,
             oldCold.ms, oldWarm.ms,
             oldCold.ms * 1000 / Double(callCount), oldWarm.ms * 1000 / Double(callCount),
             newCold.ms, newWarm.ms, flattenMs))

        for (key, stat) in perKey.sorted(by: { $0.value.ms > $1.value.ms }).prefix(5) {
            print(String(format: "   cold key %-24@ %7.1f ms  ×%-6d  %.1f µs/call",
                         key.rawValue, stat.ms, stat.n, stat.ms * 1000 / Double(stat.n)))
        }

        // Equivalence is the non-negotiable part: same attributes, either path.
        #expect(oldCold.storage.isEqual(to: newCold.storage))
        #expect(oldWarm.storage.isEqual(to: newWarm.storage))
    }
}
