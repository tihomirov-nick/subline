import Foundation

/// Applies the case/punctuation mode of a preset to subtitle text.
public enum TextTransformer {
    private static let russian = Locale(identifier: "ru_RU")

    /// Characters removed in the "without punctuation" modes.
    private static let punctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "…", "\"", "'", "«", "»", "„", "“", "”", "‟", "‘", "’", "‚",
        "(", ")", "[", "]", "{", "}", "<", ">", "‹", "›", "—", "–", "―", "‒", "-", "‐", "‑", "¡", "¿", "*", "_",
    ]
    /// Kept when they join two letters or digits: "что-то", "don't", "д'Артаньян".
    private static let joiners: Set<Character> = ["-", "‐", "‑", "'", "’"]
    /// Kept between digits: "3.5", "1,5", "10:30".
    private static let numberSeparators: Set<Character> = [".", ",", ":"]

    public static func apply(_ text: String, mode: TextCaseMode) -> String {
        var result = text
        if mode.removesPunctuation {
            result = removePunctuation(result)
        } else {
            result = normalizeSpaces(result)
        }
        if mode.lowercases {
            result = result.lowercased(with: russian)
        }
        return result
    }

    public static func removePunctuation(_ text: String) -> String {
        let chars = Array(text)
        var out = String()
        out.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() {
            guard punctuation.contains(c) else {
                out.append(c)
                continue
            }
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if joiners.contains(c), let p = prev, let n = next, isWordChar(p), isWordChar(n) {
                out.append(c)
                continue
            }
            if numberSeparators.contains(c), let p = prev, let n = next, p.isNumber, n.isNumber {
                out.append(c)
                continue
            }
            // "слово,слово" -> "слово слово"
            if let p = prev, let n = next, isWordChar(p), isWordChar(n) {
                out.append(" ")
            }
        }
        return normalizeSpaces(out)
    }

    static func normalizeSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    // MARK: - Helpers used by the subtitle builder

    /// The word ends a sentence: "дела?", "конец.", "ну…"
    static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "»\"”’)]"))
        guard let last = trimmed.last else { return false }
        return last == "." || last == "!" || last == "?" || last == "…"
    }

    /// The word ends a clause: "привет,", "итак:", "так;"
    static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return last == "," || last == ";" || last == ":" || last == "—" || last == "–"
    }

    static func startsWithDash(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return first == "—" || first == "–" || first == "-"
    }

    /// Short prepositions/conjunctions that should not end a subtitle or a line ("в", "и", "не", ...).
    private static let hangingWords: Set<String> = [
        "в", "во", "на", "и", "а", "но", "с", "со", "к", "ко", "о", "об", "обо", "у", "по", "за", "из", "изо",
        "от", "ото", "до", "не", "ни", "ли", "бы", "что", "чтобы", "как", "для", "при", "про", "без",
        "над", "под", "перед", "через", "или", "да",
        "the", "a", "an", "to", "of", "and", "in", "on", "at", "for", "with",
    ]

    static func isHanging(_ word: String) -> Bool {
        guard let last = word.last, last.isLetter else { return false }
        return hangingWords.contains(word.lowercased(with: russian))
    }
}
