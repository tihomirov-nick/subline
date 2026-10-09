import Foundation
import CoreGraphics

/// Groups recognized words into subtitles that fit the preset (lines, width, words, duration),
/// preferring breaks at sentence ends, commas and pauses.
public enum CueBuilder {
    /// Words separated by a longer pause never share a subtitle.
    static let hardPause = 1.2

    struct Item {
        let raw: String
        let start: Double
        let end: Double
        let width: CGFloat
    }

    /// `isCancelled` is asked now and then: a long transcript is cut in the background, and a newer cut can replace it.
    /// A cancelled cut returns no subtitles.
    public static func build(words: [Word], style: LayoutStyle, mediaDuration: Double? = nil,
                             isCancelled: () -> Bool = { false }) -> [Cue] {
        let preset = style.preset
        // Words are measured as the renderer draws them (capitals, highlight plates), so a subtitle built for one line
        // is drawn on one line.
        let pad = style.highlightPad
        var items: [Item] = []
        items.reserveCapacity(words.count)
        for (index, word) in words.enumerated() {
            if index % 512 == 511, isCancelled() { return [] }
            let display = style.displayText(word.text)
            guard !display.isEmpty else { continue }
            let raw = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(Item(raw: raw, start: word.start, end: max(word.end, word.start), width: style.width(display) + 2 * pad))
        }
        let n = items.count
        guard n > 0 else { return [] }

        let maxLines = max(1, preset.maxLines)
        let limit = style.maxLineWidth
        let space = style.spaceWidth
        let maxWords = preset.maxWordsPerCue > 0 ? preset.maxWordsPerCue : Int.max
        let maxDuration = max(0.8, preset.maxCueDuration)
        let widths = items.map(\.width)

        func breakCost(after k: Int) -> Double {
            let raw = items[k].raw
            let gap = items[k + 1].start - items[k].end
            var cost: Double
            if TextTransformer.endsSentence(raw) {
                cost = 0
            } else if TextTransformer.endsClause(raw) || TextTransformer.startsWithDash(items[k + 1].raw) {
                cost = 0.3
            } else {
                cost = 0.9
            }
            if gap >= 0.5 { cost = min(cost, 0.2) }
            if TextTransformer.isHanging(raw) { cost += 1.0 }
            return cost
        }

        // Dynamic programming over break positions: best[j] = cheapest split of items[0..<j].
        var best = [Double](repeating: .infinity, count: n + 1)
        var previous = [Int](repeating: -1, count: n + 1)
        best[0] = 0
        for i in 0..<n where best[i].isFinite {
            if i % 256 == 0, isCancelled() { return [] }
            var insidePenalty = 0.0
            for j in (i + 1)...n {
                let count = j - i
                if count > 1 {
                    if count > maxWords { break }
                    if items[j - 1].end - items[i].start > maxDuration { break }
                    let gap = items[j - 1].start - items[j - 2].end
                    if gap > hardPause { break }
                    let lines = LineBreaker.lineCount(widths: widths[i..<j], space: space, limit: limit, stopAfter: maxLines)
                    if lines > maxLines { break }
                    if TextTransformer.endsSentence(items[j - 2].raw) { insidePenalty += 0.6 }
                    if gap > 0.6 { insidePenalty += 0.5 }
                }
                var cost = 1.0 + insidePenalty
                if j < n { cost += breakCost(after: j - 1) }
                if count == 1 && n > 1 { cost += 0.3 }
                if best[i] + cost < best[j] {
                    best[j] = best[i] + cost
                    previous[j] = i
                }
            }
        }

        var ranges: [Range<Int>] = []
        var j = n
        while j > 0 {
            let i = previous[j]
            guard i >= 0 else { break }
            ranges.append(i..<j)
            j = i
        }
        ranges.reverse()

        var cues = ranges.map { range -> Cue in
            let text = range.map { items[$0].raw }.joined(separator: " ")
            return Cue(start: items[range.lowerBound].start, end: items[range.upperBound - 1].end, text: text)
        }
        fixTiming(&cues, mediaDuration: mediaDuration)
        return cues
    }

    /// Removes overlaps, enforces a minimal display time and closes tiny gaps to avoid flicker.
    public static func fixTiming(_ cues: inout [Cue], mediaDuration: Double?) {
        let minDuration = 0.6
        let linger = 0.25
        let mergeGap = 0.3
        let end = mediaDuration ?? .infinity
        for k in cues.indices {
            cues[k].start = max(0, min(cues[k].start, end))
            if k > 0, cues[k].start < cues[k - 1].end {
                // Overlap: trim the previous cue.
                cues[k - 1].end = max(cues[k - 1].start + 0.05, cues[k].start)
                if cues[k].start < cues[k - 1].end { cues[k].start = cues[k - 1].end }
            }
        }
        for k in cues.indices {
            let nextStart = k + 1 < cues.count ? cues[k + 1].start : end
            var e = max(cues[k].end, cues[k].start + 0.05)
            if e - cues[k].start < minDuration { e = cues[k].start + minDuration }
            e = min(max(e, cues[k].end + linger), nextStart)
            if nextStart - e < mergeGap && nextStart.isFinite { e = nextStart }
            cues[k].end = max(cues[k].start + 0.05, min(e, end.isFinite ? end : e))
        }
    }
}
