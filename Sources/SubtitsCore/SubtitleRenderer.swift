import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A word placed in the frame.
public struct PlacedWord {
    /// Index in `CueText.tokens(cue.text)`.
    public let index: Int
    public let text: String
    /// Visual bounds (cap height to descender) in video pixels, top-left origin.
    public let rect: CGRect
    let origin: CGPoint
    let path: CGPath
    let style: SubtitlePreset
    let metrics: LayoutStyle
}

/// A subtitle laid out in the frame.
public struct CueLayout {
    public let words: [PlacedWord]
    public let lineRects: [CGRect]
    /// Visual bounds of the text block.
    public let blockRect: CGRect
    /// The subtitle's style (preset → group → subtitle).
    public let style: SubtitlePreset
    let metrics: LayoutStyle

    /// Range of anchor positions (video pixels) that keep the block inside the frame.
    public func anchorRange(canvas: CGSize) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        let margins = CueRenderer.margins(metrics)
        let size = blockRect.size
        let xOffset: CGFloat
        switch style.alignment {
        case .left: xOffset = 0
        case .center: xOffset = size.width / 2
        case .right: xOffset = size.width
        }
        let yOffset: CGFloat
        switch style.anchor {
        case .top: yOffset = 0
        case .center: yOffset = size.height / 2
        case .bottom: yOffset = size.height
        }
        let minX = margins.width + xOffset
        let maxX = max(minX, canvas.width - margins.width - size.width + xOffset)
        let minY = margins.height + yOffset
        let maxY = max(minY, canvas.height - margins.height - size.height + yOffset)
        return (minX...maxX, minY...maxY)
    }

    /// Word under a point (video pixels).
    public func wordIndex(at point: CGPoint, tolerance: CGFloat = 0) -> Int? {
        words.first { $0.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }?.index
    }
}

/// Lays out and draws subtitles with CoreText. Every word can have its own font, size, slant, colors,
/// outline and highlight; the same code renders the preview and the exported video.
public final class CueRenderer {
    public let preset: SubtitlePreset
    public let canvas: CGSize
    private let groups: [UUID: SubtitleGroup]
    private var metricsCache: [SubtitlePreset: LayoutStyle] = [:]
    private let lock = NSLock()

    public init(preset: SubtitlePreset, groups: [SubtitleGroup] = [], canvas: CGSize) {
        self.preset = preset
        self.canvas = canvas
        self.groups = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Styles

    /// Style of a subtitle: preset → group → subtitle overrides.
    public func style(for cue: Cue) -> SubtitlePreset {
        var result = preset
        if let groupID = cue.groupID, let group = groups[groupID] {
            result = group.style.applied(to: result)
        }
        if let style = cue.style {
            result = style.applied(to: result)
        }
        return result
    }

    /// Style of one word inside a subtitle.
    public func style(for cue: Cue, word index: Int) -> SubtitlePreset {
        let base = style(for: cue)
        guard let override = cue.wordStyles?[index] else { return base }
        return override.wordLevel.applied(to: base)
    }

    func metrics(_ style: SubtitlePreset) -> LayoutStyle {
        lock.lock()
        defer { lock.unlock() }
        if let cached = metricsCache[style] { return cached }
        let created = LayoutStyle(preset: style, canvas: canvas)
        metricsCache[style] = created
        return created
    }

    // MARK: Layout

    private struct Token {
        let index: Int
        let text: String
        var breakAfter: Bool
        let style: SubtitlePreset
        let metrics: LayoutStyle
        let width: CGFloat
        /// Room for a highlight plate on each side of the word.
        let pad: CGFloat
    }

    /// Distance between two neighbouring words: the wider space of the two fonts plus highlight plates.
    private static func gap(_ left: Token, _ right: Token) -> CGFloat {
        max(left.metrics.spaceWidth, right.metrics.spaceWidth) + left.pad + right.pad
    }

    private static func highlightInsets(_ style: SubtitlePreset, metrics: LayoutStyle) -> CGSize {
        let size = CTFontGetSize(metrics.font)
        return CGSize(width: size * 0.16 + metrics.outline, height: size * 0.1 + metrics.outline)
    }

    private func tokens(for cue: Cue, cueStyle: SubtitlePreset) -> [Token] {
        var result: [Token] = []
        for (index, token) in CueText.tokens(cue.text).enumerated() {
            var wordStyle = cueStyle
            if let override = cue.wordStyles?[index] {
                wordStyle = override.wordLevel.applied(to: cueStyle)
            }
            var display = TextTransformer.apply(token.word, mode: wordStyle.caseMode)
            if wordStyle.uppercase { display = display.uppercased(with: Locale(identifier: "ru_RU")) }
            guard !display.isEmpty else {
                if token.breakAfter, !result.isEmpty { result[result.count - 1].breakAfter = true }
                continue
            }
            let metrics = metrics(wordStyle)
            let pad = wordStyle.highlightEnabled ? Self.highlightInsets(wordStyle, metrics: metrics).width : 0
            result.append(Token(index: index, text: display, breakAfter: token.breakAfter,
                                style: wordStyle, metrics: metrics, width: metrics.width(display), pad: pad))
        }
        return result
    }

    public func layout(_ cue: Cue) -> CueLayout? {
        let cueStyle = style(for: cue)
        let base = metrics(cueStyle)
        let words = tokens(for: cue, cueStyle: cueStyle)
        guard !words.isEmpty else { return nil }

        // Lines: manual breaks first, then balanced wrapping inside each paragraph.
        var paragraphs: [[Token]] = [[]]
        for word in words {
            paragraphs[paragraphs.count - 1].append(word)
            if word.breakAfter { paragraphs.append([]) }
        }
        paragraphs.removeAll { $0.isEmpty }
        var lines: [[Token]] = []
        for paragraph in paragraphs {
            let starts = LineBreaker.lineStarts(words: paragraph.map(\.text), widths: paragraph.map { $0.width + 2 * $0.pad },
                                                space: base.spaceWidth, limit: base.maxLineWidth)
            var start = 0
            for end in starts + [paragraph.count] {
                lines.append(Array(paragraph[start..<end]))
                start = end
            }
        }

        // Vertical metrics: the biggest word on a line sets its height.
        struct LineMetrics { var cap: CGFloat; var ascent: CGFloat; var descent: CGFloat; var leading: CGFloat; var width: CGFloat }
        let lineMetrics: [LineMetrics] = lines.map { line in
            LineMetrics(
                cap: line.map(\.metrics.capHeight).max() ?? 0,
                ascent: line.map(\.metrics.ascent).max() ?? 0,
                descent: line.map(\.metrics.descent).max() ?? 0,
                leading: line.map { CTFontGetLeading($0.metrics.font) }.max() ?? 0,
                width: line.map(\.width).reduce(0, +) + zip(line, line.dropFirst()).map { Self.gap($0, $1) }.reduce(0, +)
            )
        }
        let gap = CGFloat(cueStyle.lineGap) * base.scale
        var baselines: [CGFloat] = []
        for (i, m) in lineMetrics.enumerated() {
            if i == 0 {
                baselines.append(m.cap)
                continue
            }
            let previous = lineMetrics[i - 1]
            var advance = previous.descent + max(previous.leading, m.leading) + m.ascent + gap
            if cueStyle.boxMode == .perLine {
                // Keep line plates from overlapping.
                advance = max(advance, previous.descent * 0.85 + base.boxPadV * 2 + 2 * base.scale + m.cap)
            }
            advance = max(advance, (m.cap + previous.descent) * 0.5)
            baselines.append(baselines[i - 1] + advance)
        }
        let blockWidth = lineMetrics.map(\.width).max() ?? 0
        let blockHeight = (baselines.last ?? 0) + (lineMetrics.last?.descent ?? 0) * 0.85

        // Anchor point (left/center/right by alignment, top/center/bottom by anchor), kept inside the frame.
        let anchorX = CGFloat(cueStyle.positionX) * canvas.width
        let anchorY = CGFloat(cueStyle.positionY) * canvas.height
        var left: CGFloat
        switch cueStyle.alignment {
        case .left: left = anchorX
        case .center: left = anchorX - blockWidth / 2
        case .right: left = anchorX - blockWidth
        }
        var top: CGFloat
        switch cueStyle.anchor {
        case .top: top = anchorY
        case .center: top = anchorY - blockHeight / 2
        case .bottom: top = anchorY - blockHeight
        }
        let margins = Self.margins(base)
        left = min(max(left, margins.width), max(margins.width, canvas.width - margins.width - blockWidth))
        top = min(max(top, margins.height), max(margins.height, canvas.height - margins.height - blockHeight))

        var placed: [PlacedWord] = []
        var lineRects: [CGRect] = []
        for (i, line) in lines.enumerated() {
            let m = lineMetrics[i]
            var x: CGFloat
            switch cueStyle.alignment {
            case .left: x = left
            case .center: x = left + (blockWidth - m.width) / 2
            case .right: x = left + blockWidth - m.width
            }
            let baseline = top + baselines[i]
            let lineTop = baseline - m.cap
            let lineHeight = m.cap + m.descent * 0.85
            lineRects.append(CGRect(x: x, y: lineTop, width: m.width, height: lineHeight))
            for (position, word) in line.enumerated() {
                if position > 0 { x += Self.gap(line[position - 1], word) }
                var path = Self.glyphPath(word.metrics.makeLine(word.text))
                if word.style.slant != 0 {
                    let shear = CGAffineTransform(a: 1, b: 0, c: tan(CGFloat(word.style.slant) * .pi / 180), d: 1, tx: 0, ty: 0)
                    path = path.copy(using: [shear]) ?? path
                }
                placed.append(PlacedWord(index: word.index, text: word.text,
                                         rect: CGRect(x: x, y: lineTop, width: word.width, height: lineHeight),
                                         origin: CGPoint(x: x, y: baseline), path: path, style: word.style, metrics: word.metrics))
                x += word.width
            }
        }
        return CueLayout(words: placed, lineRects: lineRects,
                         blockRect: CGRect(x: left, y: top, width: blockWidth, height: blockHeight),
                         style: cueStyle, metrics: base)
    }

    /// Lines of display text (case/punctuation applied), e.g. for SRT.
    public func displayLines(_ cue: Cue) -> [String] {
        guard let layout = layout(cue) else { return [] }
        var lines: [String] = []
        var currentLine = -1
        var lastY: CGFloat = -.infinity
        for word in layout.words {
            if word.rect.minY != lastY {
                lines.append(word.text)
                currentLine += 1
                lastY = word.rect.minY
            } else {
                lines[currentLine] += " " + word.text
            }
        }
        return lines
    }

    /// Minimal distance between the text and the frame edges (room for the outline and the box).
    static func margins(_ metrics: LayoutStyle) -> CGSize {
        CGSize(width: metrics.outline + metrics.boxPadH + 4 * metrics.scale,
               height: metrics.outline + metrics.boxPadV + 4 * metrics.scale)
    }

    /// Outline of all glyphs of a line, in glyph space (y up, baseline at 0).
    static func glyphPath(_ line: CTLine) -> CGPath {
        let path = CGMutablePath()
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return path }
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                path.addPath(glyphPath, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
        return path
    }

    // MARK: Drawing

    /// Draws into a context whose user space is top-left based and measured in video pixels.
    /// `deviceScale` = device pixels per video pixel (needed for shadows, which ignore the CTM).
    public func draw(_ layout: CueLayout, in context: CGContext, deviceScale: CGFloat = 1) {
        let style = layout.style
        let base = layout.metrics

        // 1. Plate behind lines or the whole block
        if style.boxMode != .none, style.boxColor.a > 0 {
            context.setFillColor(style.boxColor.cgColor)
            let radius = CGFloat(style.boxCornerRadius) * base.scale
            let rects = style.boxMode == .perLine ? layout.lineRects : [layout.blockRect]
            for rect in rects {
                let plate = rect.insetBy(dx: -(base.boxPadH + base.outline), dy: -(base.boxPadV + base.outline))
                let r = min(radius, plate.height / 2, plate.width / 2)
                context.addPath(CGPath(roundedRect: plate, cornerWidth: r, cornerHeight: r, transform: nil))
                context.fillPath()
            }
        }

        // 2. Highlight plates behind single words
        for word in layout.words where word.style.highlightEnabled && word.style.highlightColor.a > 0 {
            let size = CTFontGetSize(word.metrics.font)
            let insets = Self.highlightInsets(word.style, metrics: word.metrics)
            let plate = word.rect.insetBy(dx: -insets.width, dy: -insets.height)
            let r = min(size * 0.22, plate.height / 2)
            context.setFillColor(word.style.highlightColor.cgColor)
            context.addPath(CGPath(roundedRect: plate, cornerWidth: r, cornerHeight: r, transform: nil))
            context.fillPath()
        }

        // 3. Text: shadow + outlines + fills composited as one layer so the shadow is cast once.
        func placed(_ word: PlacedWord) -> CGPath {
            let transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: word.origin.x, ty: word.origin.y)
            return word.path.copy(using: [transform]) ?? word.path
        }
        context.saveGState()
        if style.shadowEnabled, style.shadowColor.a > 0 {
            let offset = CGSize(
                width: CGFloat(style.shadowOffsetX) * base.scale * deviceScale,
                height: -CGFloat(style.shadowOffsetY) * base.scale * deviceScale
            )
            context.setShadow(offset: offset, blur: CGFloat(style.shadowBlur) * base.scale * deviceScale, color: style.shadowColor.cgColor)
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for word in layout.words where word.metrics.outline > 0 && word.style.outlineColor.a > 0 {
            context.addPath(placed(word))
            context.setLineWidth(word.metrics.outline * 2)
            context.setStrokeColor(word.style.outlineColor.cgColor)
            context.strokePath()
        }
        for word in layout.words {
            context.addPath(placed(word))
            context.setFillColor(word.style.textColor.cgColor)
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: Bitmaps

    /// A transparent RGBA bitmap context of `pixelSize` whose user space is the video frame
    /// (top-left origin, video pixels).
    public static func makeContext(canvas: CGSize, pixelSize: CGSize) -> CGContext? {
        let width = max(1, Int(pixelSize.width.rounded()))
        let height = max(1, Int(pixelSize.height.rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / canvas.width, y: -CGFloat(height) / canvas.height)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        return context
    }

    /// The subtitle on a transparent image (`outputScale` 1 = video resolution).
    public func makeImage(_ cue: Cue, outputScale: CGFloat = 1) -> CGImage? {
        let pixelSize = CGSize(width: canvas.width * outputScale, height: canvas.height * outputScale)
        guard let context = Self.makeContext(canvas: canvas, pixelSize: pixelSize) else { return nil }
        if let layout = layout(cue) {
            draw(layout, in: context, deviceScale: outputScale)
        }
        return context.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
