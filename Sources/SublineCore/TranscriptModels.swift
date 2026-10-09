import Foundation

/// One recognized word with its timing (seconds). `text` keeps the original case and attached punctuation.
public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var probability: Float

    public init(text: String, start: Double, end: Double, probability: Float = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// A segment as produced by Whisper (roughly a phrase or a sentence).
public struct TranscriptSegment: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]

    public init(start: Double, end: Double, text: String, words: [Word]) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// The full result of speech recognition for one media file.
public struct Transcript: Codable, Sendable {
    public var language: String
    public var modelName: String
    public var duration: Double
    public var segments: [TranscriptSegment]
    public var createdAt: Date

    public init(language: String, modelName: String, duration: Double, segments: [TranscriptSegment], createdAt: Date = Date()) {
        self.language = language
        self.modelName = modelName
        self.duration = duration
        self.segments = segments
        self.createdAt = createdAt
    }

    public var words: [Word] { segments.flatMap(\.words) }
}

/// One subtitle shown on screen. `text` keeps the original case and punctuation; the case/punctuation mode
/// and line breaks are applied when rendering. Styling is layered: preset → group → `style` → `wordStyles`.
public struct Cue: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var groupID: UUID?
    /// Overrides for this subtitle (font, colors, position, ...).
    public var style: StyleOverride?
    /// Overrides for single words, keyed by word index (see `CueText.tokens`).
    public var wordStyles: [Int: StyleOverride]?

    public init(id: UUID = UUID(), start: Double, end: Double, text: String,
                groupID: UUID? = nil, style: StyleOverride? = nil, wordStyles: [Int: StyleOverride]? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.groupID = groupID
        self.style = style
        self.wordStyles = wordStyles
    }

    enum CodingKeys: String, CodingKey {
        case id, start, end, text, groupID, style, wordStyles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        style = try c.decodeIfPresent(StyleOverride.self, forKey: .style)
        wordStyles = try c.decodeIfPresent([Int: StyleOverride].self, forKey: .wordStyles)
    }

    /// The subtitle has its own look (not only the preset's).
    public var hasCustomStyle: Bool {
        !(style?.isEmpty ?? true) || !(wordStyles?.isEmpty ?? true)
    }

    /// Replaces the text, keeping the styles of words that did not change.
    public mutating func setText(_ newText: String) {
        if let styles = wordStyles, !styles.isEmpty {
            let remapped = CueText.remap(styles, from: text, to: newText)
            wordStyles = remapped.isEmpty ? nil : remapped
        }
        text = newText
    }
}

/// Words of subtitle text. Word indices are stable references for per-word styles.
public enum CueText {
    public struct Token: Equatable {
        public let word: String
        /// A manual line break follows this word.
        public let breakAfter: Bool
    }

    public static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        let paragraphs = text.components(separatedBy: "\n")
        for (p, paragraph) in paragraphs.enumerated() {
            let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for (i, word) in words.enumerated() {
                let last = i == words.count - 1 && p < paragraphs.count - 1
                result.append(Token(word: word, breakAfter: last))
            }
        }
        return result
    }

    public static func words(_ text: String) -> [String] { tokens(text).map(\.word) }

    /// Moves word styles to the same words in the edited text (longest common subsequence).
    public static func remap(_ styles: [Int: StyleOverride], from old: String, to new: String) -> [Int: StyleOverride] {
        let a = words(old)
        let b = words(new)
        guard !a.isEmpty, !b.isEmpty else { return [:] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var mapping: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                mapping[i] = j
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var result: [Int: StyleOverride] = [:]
        for (oldIndex, style) in styles {
            if let newIndex = mapping[oldIndex] { result[newIndex] = style }
        }
        return result
    }
}

public extension Array where Element == Cue {
    /// The cue visible at time `t`, if any.
    func cue(at t: Double) -> Cue? {
        first { t >= $0.start && t < $0.end }
    }
}

/// Formats seconds as 00:01:02.345 (or 01:02.3 when `short`).
public func formatTimecode(_ seconds: Double, short: Bool = false) -> String {
    let s = max(0, seconds)
    let totalMs = Int((s * 1000).rounded())
    let h = totalMs / 3_600_000
    let m = (totalMs / 60_000) % 60
    let sec = (totalMs / 1000) % 60
    let ms = totalMs % 1000
    if short {
        if h > 0 { return String(format: "%d:%02d:%02d.%d", h, m, sec, ms / 100) }
        return String(format: "%02d:%02d.%d", m, sec, ms / 100)
    }
    return String(format: "%02d:%02d:%02d.%03d", h, m, sec, ms)
}

/// Times in the interface, one style everywhere: "0:12.48", and "0:00:12.48" for a video of an hour or longer, where
/// every time has the hours so that the columns line up. Centiseconds are rounded to the nearest.
public struct ClockFormat: Equatable, Sendable {
    public let showsHours: Bool

    public init(duration: Double) {
        showsHours = duration >= 3600
    }

    public func string(_ seconds: Double) -> String {
        // A small epsilon: 9.2 s reads 9.20, not 9.19 (binary floating point).
        let total = Int((max(0, seconds) * 100 + 0.001).rounded())
        let cs = total % 100
        let s = (total / 100) % 60
        let m = (total / 6000) % 60
        let h = total / 360_000
        if showsHours || h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, cs) }
        return String(format: "%d:%02d.%02d", total / 6000, s, cs)
    }

    /// The longest text of this format, for the width of a field: "00:00.00" or "0:00:00.00".
    public var widest: String { showsHours ? "0:00:00.00" : "00:00.00" }
}

/// Parses "1:02.5", "00:01:02,345", "62.5" into seconds.
public func parseTimecode(_ text: String) -> Double? {
    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard !cleaned.isEmpty else { return nil }
    let parts = cleaned.split(separator: ":").map(String.init)
    guard parts.count <= 3 else { return nil }
    var total = 0.0
    for part in parts {
        guard let value = Double(part), value >= 0 else { return nil }
        total = total * 60 + value
    }
    return total
}
