//
//  InlineLatexWidthTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 26.07.26.
//
//  Guards the ENG-8g2b hoist+memo (per-formula CoreText width measurement).
//  The styled widths must be bit-identical to direct `HeadingHelpers.textWidth`,
//  and repeated formulas must produce byte-identical ranges.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

/// Deterministic stub so the render (else) branch — the only path that measures
/// widths — actually runs. Size depends solely on the latex string, so a formula
/// that repeats yields the same `entry.size`, exactly like a real renderer.
private struct StubLatexRenderer: LatexRenderer {
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        let size = CGSize(width: CGFloat(latex.count) * 7.0 + 3.0, height: fontSize + 2.0)
        return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: 1.5)
    }
}

@Suite("ENG-8g2b inline LaTeX width memoization")
@MainActor
struct InlineLatexWidthTests {

    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }
    private let base: CGFloat = 14

    private func style(_ text: String) -> ([StyledRange], MarkdownEditorConfiguration) {
        _ = NSApplication.shared
        let config = MarkdownEditorConfiguration(
            services: MarkdownEditorServices(latex: StubLatexRenderer())
        )
        let attrs = MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: base,
            caretLocation: 0, activeTokenIndices: [], configuration: config
        )
        return (attrs, config)
    }

    /// The same (string, font) must measure identically every time — the memo's
    /// correctness rests on this.
    @Test("textWidth is deterministic per (string, font)")
    func textWidthDeterministic() {
        let font = NSFont.systemFont(ofSize: 0.1)
        let a = HeadingHelpers.textWidth("x^2", font: font)
        let b = HeadingHelpers.textWidth("x^2", font: font)
        #expect(a == b)
    }

    /// Styling a doc with DISTINCT and REPEATED inline formulas must produce
    /// widths bit-identical to direct measurement, and repeats must be identical.
    @Test("memoized widths equal direct measurement; repeats are byte-identical")
    func memoMatchesDirectMeasurement() {
        // Two distinct formulas, each repeated: $x^2$ ×3, $y_3$ ×2.
        let text = "a $x^2$ b $y_3$ c $x^2$ d $y_3$ e $x^2$ f"
        let (attrs, config) = style(text)
        let ns = text as NSString

        let baseFont = NSFont(name: fontName, size: base) ?? .systemFont(ofSize: base)
        let markerSize = config.markers.hiddenMarkerFontSize
        let markerFont = NSFont(name: fontName, size: markerSize) ?? .systemFont(ofSize: markerSize)
        let tinyDollar = HeadingHelpers.textWidth("$", font: markerFont)
        let baseDollar = HeadingHelpers.textWidth("$", font: baseFont)

        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: config.extensionRegistry)
            .filter { $0.kind == .inlineLatex }
        #expect(tokens.count == 5)   // 3× x^2 + 2× y_3

        // Find the styled range that exactly matches `r` and satisfies `where`.
        func styled(_ r: NSRange, where match: ([NSAttributedString.Key: Any]) -> Bool) -> [NSAttributedString.Key: Any]? {
            attrs.first { NSEqualRanges($0.range, r) && match($0.attributes) }?.attributes
        }

        // Collect firstChar kerns keyed by the formula's content, to prove repeats match.
        var firstKernByContent: [String: CGFloat] = [:]
        var restKernByContent: [String: CGFloat] = [:]

        for token in tokens {
            let content = ns.substring(with: token.contentRange)         // e.g. "x^2"
            let size = CGSize(width: CGFloat(content.count) * 7.0 + 3.0, height: base + 2.0)
            let expectedBounds = CGRect(x: 0, y: 1.5, width: size.width, height: size.height)

            // firstChar: carries the image + bounds + kern.
            let firstRange = NSRange(location: token.contentRange.location, length: 1)
            let firstChar = ns.substring(with: firstRange)
            let expectedFirstKern = size.width - HeadingHelpers.textWidth(firstChar, font: markerFont)
            let firstAttrs = styled(firstRange) { $0[.latexImage] != nil }
            #expect(firstAttrs != nil)
            #expect(firstAttrs?[.kern] as? CGFloat == expectedFirstKern)
            #expect((firstAttrs?[.latexBounds] as? NSValue)?.rectValue == expectedBounds)
            if let prior = firstKernByContent[content] { #expect(prior == expectedFirstKern) }
            firstKernByContent[content] = expectedFirstKern

            // rest: kern only (content length here is always > 1).
            let restRange = NSRange(location: token.contentRange.location + 1, length: token.contentRange.length - 1)
            let restText = ns.substring(with: restRange)
            let expectedRestKern = -HeadingHelpers.textWidth(restText, font: markerFont)
            let restAttrs = styled(restRange) { $0[.latexImage] == nil && $0[.kern] != nil }
            #expect(restAttrs?[.kern] as? CGFloat == expectedRestKern)
            if let prior = restKernByContent[content] { #expect(prior == expectedRestKern) }
            restKernByContent[content] = expectedRestKern

            // markers: invariant "$" widths.
            let open = styled(token.markerRanges[0]) { $0[.kern] != nil }
            let close = styled(token.markerRanges[1]) { $0[.kern] != nil }
            #expect(open?[.kern] as? CGFloat == -tinyDollar)
            #expect(close?[.kern] as? CGFloat == -baseDollar)
        }
    }
}
