import Foundation
import CoreText
import CoreGraphics

/// A preset resolved for a concrete frame size: the font and all sizes in video pixels.
/// Used both to group words into subtitles and to draw them, so preview and export match exactly.
public final class LayoutStyle {
    public let preset: SubtitlePreset
    public let canvas: CGSize
    /// Video pixels per preset pixel (presets are defined for a 1080 px short side).
    public let scale: CGFloat
    public let font: CTFont
    public let fontIsFallback: Bool
    public let resolvedFamily: String
    public let kern: CGFloat
    public let outline: CGFloat
    public let boxPadH: CGFloat
    public let boxPadV: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let capHeight: CGFloat
    public let lineAdvance: CGFloat
    public private(set) var spaceWidth: CGFloat = 0

    private var widthCache: [String: CGFloat] = [:]
    private let cacheLock = NSLock()

    public init(preset: SubtitlePreset, canvas: CGSize) {
        self.preset = preset
        self.canvas = canvas
        let shortSide = max(1, min(canvas.width, canvas.height))
        scale = shortSide / CGFloat(SubtitlePreset.referenceShortSide)
        let pointSize = max(4, CGFloat(preset.fontSize) * scale)
        let resolved = FontLibrary.resolve(family: preset.fontFamily, face: preset.fontFace, size: pointSize)
        font = resolved.font
        fontIsFallback = resolved.isFallback
        resolvedFamily = resolved.familyName
        kern = CGFloat(preset.letterSpacing) * scale
        outline = preset.outlineEnabled ? max(0, CGFloat(preset.outlineWidth) * scale) : 0
        let pad = preset.boxMode == .none ? 0 : max(0, CGFloat(preset.boxPadding) * scale)
        boxPadH = pad
        boxPadV = pad * 0.6
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        let cap = CTFontGetCapHeight(font)
        capHeight = cap > 0 ? cap : ascent * 0.7
        var advance = ascent + descent + CTFontGetLeading(font) + CGFloat(preset.lineGap) * scale
        advance = max(advance, (ascent + descent) * 0.5)
        if preset.boxMode == .perLine {
            // Keep line boxes from overlapping.
            advance = max(advance, capHeight + descent * 0.85 + boxPadV * 2 + 2 * scale)
        }
        lineAdvance = advance
        spaceWidth = max(0, width("x x") - 2 * width("x"))
    }

    /// Text area width available for one line.
    public var maxLineWidth: CGFloat {
        max(40 * scale, CGFloat(preset.maxWidth) * canvas.width - 2 * outline - 2 * boxPadH)
    }

    /// A word as it is drawn: the case and punctuation mode, then capitals when the style asks for them.
    public func displayText(_ word: String) -> String {
        let display = TextTransformer.apply(word, mode: preset.caseMode)
        return preset.uppercase ? display.uppercased(with: Locale(identifier: "ru_RU")) : display
    }

    /// Room around a word for its highlight plate (zero without the plate on the sides).
    public var highlightInsets: CGSize {
        let size = CTFontGetSize(font)
        return CGSize(width: size * 0.16 + outline, height: size * 0.1 + outline)
    }

    /// The plate's room on each side of a word, as the renderer leaves it between words.
    var highlightPad: CGFloat { preset.highlightEnabled ? highlightInsets.width : 0 }

    public func attributedString(_ text: String) -> CFAttributedString {
        var attributes: [CFString: Any] = [kCTFontAttributeName: font]
        if kern != 0 {
            attributes[kCTKernAttributeName] = NSNumber(value: Double(kern))
        }
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }

    public func makeLine(_ text: String) -> CTLine {
        CTLineCreateWithAttributedString(attributedString(text))
    }

    /// Advance width of the text (letter spacing after the last character is not counted).
    public func width(_ text: String) -> CGFloat {
        cacheLock.lock()
        if let cached = widthCache[text] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        var w = CGFloat(CTLineGetTypographicBounds(makeLine(text), nil, nil, nil))
        if kern != 0, !text.isEmpty { w -= kern }
        cacheLock.lock()
        widthCache[text] = w
        cacheLock.unlock()
        return w
    }
}

/// Splits subtitle text into lines that fit the preset width, balancing line lengths.
public enum LineBreaker {
    /// Lines for already transformed (display) text. Manual line breaks ("\n") are kept.
    public static func lines(for text: String, style: LayoutStyle, maxLines: Int) -> [String] {
        let manual = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if manual.count > 1 {
            return manual.flatMap { breakParagraph(String($0), style: style, maxLines: 1) }
        }
        return breakParagraph(manual.first ?? "", style: style, maxLines: maxLines)
    }

    static func breakParagraph(_ text: String, style: LayoutStyle, maxLines: Int) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        let breaks = lineStarts(words: words, widths: words.map { style.width($0) },
                                space: style.spaceWidth, limit: style.maxLineWidth)
        var result: [String] = []
        var start = 0
        for b in breaks + [words.count] {
            result.append(words[start..<b].joined(separator: " "))
            start = b
        }
        return result
    }

    /// Indices of the words that start a new line (balanced lines that fit `limit`).
    public static func lineStarts(words: [String], widths: [CGFloat], space: CGFloat, limit: CGFloat) -> [Int] {
        let n = words.count
        guard n > 1 else { return [] }

        func span(_ a: Int, _ b: Int) -> CGFloat {
            var total: CGFloat = 0
            for i in a..<b { total += widths[i] }
            return total + CGFloat(b - a - 1) * space
        }

        if span(0, n) <= limit { return [] }
        let needed = greedyBreaks(widths: widths, space: space, limit: limit)
        let lineCount = needed.count + 1

        // Prefer line breaks after a sentence or a clause, avoid leaving prepositions at the end of a line.
        func breakPenalty(after index: Int) -> CGFloat {
            var p: CGFloat = 0
            if TextTransformer.isHanging(words[index]) { p += 0.3 }
            if TextTransformer.endsSentence(words[index]) {
                p -= 0.3
            } else if TextTransformer.endsClause(words[index]) {
                p -= 0.15
            }
            return p
        }

        if lineCount == 2 {
            var best: (cost: CGFloat, k: Int)?
            for k in 1..<n {
                let w1 = span(0, k), w2 = span(k, n)
                guard w1 <= limit, w2 <= limit else { continue }
                // Balanced lines; slight preference for a shorter top line.
                var cost = max(w1, w2) / limit + breakPenalty(after: k - 1)
                if w1 > w2 { cost += 0.03 }
                if best == nil || cost < best!.cost { best = (cost, k) }
            }
            if let k = best?.k { return [k] }
        } else if lineCount == 3 && n >= 3 {
            var best: (cost: CGFloat, k1: Int, k2: Int)?
            for k1 in 1..<(n - 1) {
                let w1 = span(0, k1)
                guard w1 <= limit else { break }
                for k2 in (k1 + 1)..<n {
                    let w2 = span(k1, k2), w3 = span(k2, n)
                    guard w2 <= limit else { break }
                    guard w3 <= limit else { continue }
                    let cost = max(w1, w2, w3) / limit + breakPenalty(after: k1 - 1) + breakPenalty(after: k2 - 1)
                    if best == nil || cost < best!.cost { best = (cost, k1, k2) }
                }
            }
            if let b = best { return [b.k1, b.k2] }
        }
        // Greedy wrap (also used when the text needs more lines than allowed, e.g. after manual edits).
        return needed
    }

    /// Indices where greedy wrapping starts a new line.
    static func greedyBreaks(widths: [CGFloat], space: CGFloat, limit: CGFloat) -> [Int] {
        var breaks: [Int] = []
        var current: CGFloat = -1
        for (i, w) in widths.enumerated() {
            if current < 0 {
                current = w
            } else if current + space + w <= limit {
                current += space + w
            } else {
                breaks.append(i)
                current = w
            }
        }
        return breaks
    }

    /// Number of lines greedy wrapping needs for these word widths.
    static func lineCount(widths: ArraySlice<CGFloat>, space: CGFloat, limit: CGFloat, stopAfter maxLines: Int) -> Int {
        var lines = 0
        var current: CGFloat = -1
        for w in widths {
            if current < 0 {
                current = w
                lines = 1
            } else if current + space + w <= limit {
                current += space + w
            } else {
                lines += 1
                if lines > maxLines { return lines }
                current = w
            }
        }
        return lines
    }
}
