import Foundation

// Editing the text of subtitles by hand: typed and pasted text, words moved between neighbours, cutting and joining.
// Everything here works on plain values, so the window and the tests share it.

public extension CueText {
    /// Line breaks of every kind ("\r\n", "\r", U+2028, U+2029) as "\n" and tabs as spaces. Without line breaks (a
    /// one-line style) every break becomes a space. Each character keeps its place, so the caret stays where it was.
    static func normalizedInput(_ text: String, allowsLineBreaks: Bool) -> String {
        guard text.contains(where: { $0.isNewline || $0 == "\t" }) else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        for character in text {
            if character.isNewline {
                out.append(allowsLineBreaks ? "\n" : " ")
            } else if character == "\t" {
                out.append(" ")
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// Ranges of the words of `text`, in the order of `tokens`.
    static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begin = start { ranges.append(begin..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let begin = start { ranges.append(begin..<text.endIndex) }
        return ranges
    }

    /// The word a cut at the caret starts the second part with: the number of words that begin before the caret
    /// (`offset` in UTF-16 units, as AppKit counts it). A word with the caret inside stays in the first part.
    static func wordIndex(atUTF16Offset offset: Int, in text: String) -> Int {
        let utf16 = text.utf16
        let clamped = min(max(0, offset), utf16.count)
        let caret = String.Index(utf16Offset: clamped, in: text)
        return wordRanges(text).filter { $0.lowerBound < caret }.count
    }

    /// The text before word `k` and the text from it on. Line breaks inside each part stay.
    static func split(_ text: String, beforeWord k: Int) -> (String, String) {
        let ranges = wordRanges(text)
        guard k > 0 else { return ("", text) }
        guard k < ranges.count else { return (text, "") }
        let first = String(text[..<ranges[k].lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(text[ranges[k].lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (first, second)
    }

    /// The word as it sounds, for matching subtitle words with recognized ones: lower case, letters and digits.
    static func spoken(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// Changes to the list of subtitles made by hand. Times follow the words: recognized word times when the words of the
/// subtitle match them, otherwise the share of the text.
public enum CueEditor {
    /// The shortest time a subtitle keeps after words move out of it.
    public static let minimumDuration = 0.25

    /// Moves the last word of subtitle `index` to the start of the next one. The cut moves to the moment that word is
    /// said, so it shows while it sounds; a pause before the next subtitle is taken by it. Moving the only word joins
    /// the two subtitles.
    @discardableResult
    public static func moveLastWordToNext(_ cues: inout [Cue], at index: Int, words: [Word] = []) -> Bool {
        guard cues.indices.contains(index), index + 1 < cues.count else { return false }
        let source = cues[index]
        let count = CueText.words(source.text).count
        guard count > 0 else { return false }
        if count == 1 {
            // Nothing stays: the word joins the next subtitle, which takes over the time of this one.
            var target = cues[index + 1]
            target.wordStyles = shifted(target.wordStyles, by: 1, adding: source.wordStyles?[0].map { [0: $0] })
            target.text = join(source.text, target.text)
            target.start = min(source.start, target.start)
            cues[index + 1] = target
            cues.remove(at: index)
            return true
        }
        let cut = boundary(of: source, beforeWord: count - 1, words: words)
        let (rest, word) = CueText.split(source.text, beforeWord: count - 1)
        var target = cues[index + 1]
        target.wordStyles = shifted(target.wordStyles, by: 1, adding: source.wordStyles?[count - 1].map { [0: $0] })
        target.text = join(word, target.text)
        target.start = min(target.start, cut)
        var trimmed = source
        trimmed.text = rest
        trimmed.wordStyles = kept(source.wordStyles, below: count - 1)
        trimmed.end = cut
        cues[index] = trimmed
        cues[index + 1] = target
        return true
    }

    /// Moves the first word of subtitle `index` to the end of the previous one, which then lasts until that word is
    /// said. Moving the only word joins the two subtitles.
    @discardableResult
    public static func moveFirstWordToPrevious(_ cues: inout [Cue], at index: Int, words: [Word] = []) -> Bool {
        guard cues.indices.contains(index), index > 0 else { return false }
        let source = cues[index]
        let count = CueText.words(source.text).count
        guard count > 0 else { return false }
        var target = cues[index - 1]
        let targetCount = CueText.words(target.text).count
        if count == 1 {
            target.wordStyles = merged(target.wordStyles, source.wordStyles, offset: targetCount)
            target.text = join(target.text, source.text)
            target.end = max(target.end, source.end)
            cues[index - 1] = target
            cues.remove(at: index)
            return true
        }
        let cut = boundary(of: source, beforeWord: 1, words: words)
        let (word, rest) = CueText.split(source.text, beforeWord: 1)
        target.wordStyles = merged(target.wordStyles, source.wordStyles?[0].map { [0: $0] }, offset: targetCount)
        target.text = join(target.text, word)
        target.end = max(target.end, cut)
        var trimmed = source
        trimmed.text = rest
        trimmed.wordStyles = shifted(source.wordStyles, by: -1, adding: nil)
        trimmed.start = cut
        cues[index - 1] = target
        cues[index] = trimmed
        return true
    }

    /// Cuts subtitle `index` before word `k`. The cut happens at `time` when it is given (the playhead), otherwise when
    /// word `k` is said. The second part keeps the group and the style of the subtitle.
    @discardableResult
    public static func split(_ cues: inout [Cue], at index: Int, beforeWord k: Int, time: Double? = nil, words: [Word] = []) -> Bool {
        guard cues.indices.contains(index) else { return false }
        let cue = cues[index]
        let count = CueText.words(cue.text).count
        guard k > 0, k < count else { return false }
        var cut = time ?? boundary(of: cue, beforeWord: k, words: words)
        cut = clamp(cut, cue.start + min(minimumDuration, (cue.end - cue.start) / 2),
                    cue.end - min(minimumDuration, (cue.end - cue.start) / 2))
        var (first, second) = parts(of: cue, beforeWord: k)
        first.end = cut
        second.start = cut
        second.end = cue.end
        cues[index] = first
        cues.insert(second, at: index + 1)
        return true
    }

    /// Joins subtitle `index` with the next one: one text, the time of both, the group and the style of the first.
    @discardableResult
    public static func mergeWithNext(_ cues: inout [Cue], at index: Int) -> Bool {
        guard cues.indices.contains(index), index + 1 < cues.count else { return false }
        let next = cues.remove(at: index + 1)
        let offset = CueText.words(cues[index].text).count
        cues[index].wordStyles = merged(cues[index].wordStyles, next.wordStyles, offset: offset)
        cues[index].text = join(cues[index].text, next.text)
        cues[index].end = max(cues[index].end, next.end)
        return true
    }

    /// The word to cut at for a moment inside the subtitle: the recognized word that starts closest to it, otherwise
    /// the share of the words that matches the share of the time. Nil when no cut leaves words on both sides.
    public static func wordIndex(at time: Double, in cue: Cue, words: [Word] = []) -> Int? {
        let count = CueText.words(cue.text).count
        guard count > 1, cue.end > cue.start else { return nil }
        let times = timings(of: cue, words: words)
        let candidates = (1..<count).compactMap { k in times[k].map { (k, abs($0.start - time)) } }
        if let nearest = candidates.min(by: { $0.1 < $1.1 }) { return nearest.0 }
        let fraction = (time - cue.start) / (cue.end - cue.start)
        return min(max(1, Int((Double(count) * fraction).rounded())), count - 1)
    }

    // MARK: Parts

    /// The two subtitles a cut before word `k` makes, with the word styles divided (times stay those of `cue`).
    static func parts(of cue: Cue, beforeWord k: Int) -> (Cue, Cue) {
        let (firstText, secondText) = CueText.split(cue.text, beforeWord: k)
        var first = cue
        first.text = firstText
        first.wordStyles = kept(cue.wordStyles, below: k)
        var second = Cue(start: cue.start, end: cue.end, text: secondText, groupID: cue.groupID, style: cue.style)
        second.wordStyles = shifted(cue.wordStyles, by: -k, adding: nil)
        return (first, second)
    }

    // MARK: Times

    /// When the text of the subtitle is cut before word `k`: when that word starts being said (or the word before it
    /// ends) if the words match the recognized ones, otherwise at the share of the characters before it.
    static func boundary(of cue: Cue, beforeWord k: Int, words: [Word]) -> Double {
        let duration = max(0, cue.end - cue.start)
        let margin = min(minimumDuration, duration / 2)
        let times = timings(of: cue, words: words)
        let time: Double
        if let next = times[k] {
            time = next.start
        } else if let previous = times[k - 1] {
            time = previous.end
        } else {
            let all = CueText.words(cue.text)
            let before = all[..<k].map(\.count).reduce(0, +) + k
            let total = all.map(\.count).reduce(0, +) + all.count
            time = cue.start + duration * Double(before) / Double(max(1, total))
        }
        return clamp(time, cue.start + margin, cue.end - margin)
    }

    /// Times of the subtitle's words that match recognized words said inside the subtitle (by word index).
    static func timings(of cue: Cue, words: [Word]) -> [Int: (start: Double, end: Double)] {
        let said = words.filter { word in
            let middle = (word.start + word.end) / 2
            return middle >= cue.start && middle <= cue.end
        }
        let a = CueText.words(cue.text).map(CueText.spoken)
        let b = said.map { CueText.spoken($0.text) }
        guard !a.isEmpty, !b.isEmpty else { return [:] }
        // The longest common subsequence pairs the words that stayed after the edits.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = !a[i].isEmpty && a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Int: (start: Double, end: Double)] = [:]
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if !a[i].isEmpty && a[i] == b[j] {
                result[i] = (said[j].start, said[j].end)
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    // MARK: Helpers

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard low <= high else { return (low + high) / 2 }
        return min(max(value, low), high)
    }

    private static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    /// Word styles below index `limit`.
    private static func kept(_ styles: [Int: StyleOverride]?, below limit: Int) -> [Int: StyleOverride]? {
        guard let styles else { return nil }
        let result = styles.filter { $0.key < limit }
        return result.isEmpty ? nil : result
    }

    /// Word styles moved by `offset` (those that fall before the first word are dropped), plus `adding` as they are.
    private static func shifted(_ styles: [Int: StyleOverride]?, by offset: Int,
                                adding: [Int: StyleOverride]?) -> [Int: StyleOverride]? {
        var result: [Int: StyleOverride] = [:]
        for (index, style) in styles ?? [:] where index + offset >= 0 { result[index + offset] = style }
        for (index, style) in adding ?? [:] { result[index] = style }
        return result.isEmpty ? nil : result
    }

    /// The styles of the first text and those of the second one after it (`offset` words in).
    private static func merged(_ first: [Int: StyleOverride]?, _ second: [Int: StyleOverride]?,
                               offset: Int) -> [Int: StyleOverride]? {
        var result = first ?? [:]
        for (index, style) in second ?? [:] { result[index + offset] = style }
        return result.isEmpty ? nil : result
    }
}
