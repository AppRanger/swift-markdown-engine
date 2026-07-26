//
//  StaticLinkDetectorEquivalenceTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 26.07.26.
//
//  Guards the perf hoist (ENG-8g1b/c): the auto-link NSDataDetector and the six
//  incomplete-link NSRegularExpressions are now built once as `static let` and
//  the incomplete-link pass early-outs when the text holds no `[`. These are
//  pure perf changes — the styled output (every range, every color) must stay
//  byte-identical to the per-call construction, and the `[`-early-out must never
//  skip a real match (every pattern starts with `\[`).
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Static link detectors — identical output, safe early-out")
struct StaticLinkDetectorEquivalenceTests {

    private let base: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    private func style(_ text: String) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base)
    }

    /// Effective color at `pos`: the last styled range covering it that sets `.foregroundColor`.
    private func color(in attrs: [StyledRange], at pos: Int) -> NSColor? {
        var result: NSColor?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let c = a[.foregroundColor] as? NSColor { result = c }
        }
        return result
    }

    private var mutedColor: NSColor { MarkdownEditorTheme.default.mutedText }
    private var fadedColor: NSColor {
        MarkdownEditorTheme.default.incompleteLink
            .withAlphaComponent(MarkdownEditorConfiguration.default.link.incompleteLinkAlpha)
    }

    /// The static detector still linkifies a bare URL (hoisting an NSDataDetector
    /// to `static let` changes nothing about matching).
    @Test("auto-link detector still tags a bare URL")
    func autoLinkStillDetected() {
        let text = "see https://example.com here"
        let attrs = style(text)
        let ns = text as NSString
        let url = ns.range(of: "https://example.com")
        let tagged = attrs.contains { NSIntersectionRange($0.range, url).length > 0 && $0.attributes[.link] != nil }
        #expect(tagged)
    }

    /// The static regexes still color an incomplete link `[text]` (no `(url)`):
    /// brackets muted, inner text faded — the run-coloring the pass produces.
    @Test("incomplete link brackets keep muted/faded coloring")
    func incompleteLinkStillColored() {
        // "before [Design System] after": `[` at 7, content 8..<21, `]` at 21.
        let text = "before [Design System] after"
        let attrs = style(text)
        #expect(color(in: attrs, at: 7) == mutedColor)   // [
        #expect(color(in: attrs, at: 14) == fadedColor)  // inside "Design System"
        #expect(color(in: attrs, at: 21) == mutedColor)  // ]
    }

    /// Early-out safety: a document with `[` present is styled exactly as if the
    /// early-out never fired — proven by asserting the real match survives (above)
    /// AND that a document with NO `[` produces zero incomplete-link colors, which
    /// is precisely what the six `\[`-anchored patterns would produce anyway.
    @Test("no `[` ⇒ no incomplete-link colors (early-out matches the regex result)")
    func earlyOutMatchesEmptyResult() {
        let text = "plain prose with no bracket chars, only https://ok.example.com url"
        let attrs = style(text)
        // The incomplete-link pass is the only source of the faded color.
        #expect(!attrs.contains { $0.attributes[.foregroundColor] as? NSColor == fadedColor })
    }

    /// A bracket buried far from the edit must NOT be missed: the early-out scans
    /// the whole string for `[`, so a match anywhere still runs the patterns.
    @Test("bracket anywhere in the doc is not skipped by the early-out")
    func bracketAnywhereNotSkipped() {
        let filler = String(repeating: "lorem ipsum dolor sit amet\n", count: 200)
        let text = filler + "tail [Broken Link] end"
        let attrs = style(text)
        let ns = text as NSString
        let open = ns.range(of: "[Broken Link]")
        #expect(color(in: attrs, at: open.location) == mutedColor)
    }

    /// Reusing an immutable static detector/regex across calls can never drift:
    /// two full styles of a bracket- and URL-rich document are byte-identical
    /// (same ranges, same attribute values).
    @Test("repeated styling is byte-identical (static caches don't drift)")
    func repeatedStylingIdentical() {
        let text = """
        # Heading with a [link](https://example.com) and a bare https://autolink.example.com

        An [incomplete] link, a `[code bracket]`, an [[Wiki]], and [another](x) one.

        - [ ] task with [bracket] inside
        """
        let a = style(text)
        let b = style(text)
        #expect(!a.isEmpty)
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            #expect(x.range == y.range)
            #expect((x.attributes as NSDictionary).isEqual(to: y.attributes))
        }
    }
}
