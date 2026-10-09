import Foundation
import CoreGraphics

/// Color stored as RGBA components in 0...1 (sRGB).
public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let yellow = RGBAColor(r: 1, g: 0.86, b: 0.1)

    public func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: alpha) }

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a].map { CGFloat($0) })!
    }
}

/// The four case/punctuation variants of the subtitle text.
public enum TextCaseMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Upper and lower case, with punctuation
    case original
    /// Upper and lower case, without punctuation
    case originalNoPunctuation
    /// Lower case only, with punctuation
    case lowercase
    /// Lower case only, without punctuation
    case lowercaseNoPunctuation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: return L("Заглавные и строчные, со знаками препинания")
        case .originalNoPunctuation: return L("Заглавные и строчные, без знаков препинания")
        case .lowercase: return L("Все строчные, со знаками препинания")
        case .lowercaseNoPunctuation: return L("Все строчные, без знаков препинания")
        }
    }

    public var shortTitle: String {
        switch self {
        case .original: return L("Аа  ,.!?")
        case .originalNoPunctuation: return L("Аа")
        case .lowercase: return L("аа  ,.!?")
        case .lowercaseNoPunctuation: return L("аа")
        }
    }

    public var removesPunctuation: Bool { self == .originalNoPunctuation || self == .lowercaseNoPunctuation }
    public var lowercases: Bool { self == .lowercase || self == .lowercaseNoPunctuation }
}

public enum TextAlignmentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, center, right
    public var id: String { rawValue }
}

/// Which point of the text block the vertical position refers to.
public enum VerticalAnchor: String, Codable, CaseIterable, Identifiable, Sendable {
    case top, center, bottom
    public var id: String { rawValue }
}

/// Background box behind the text.
public enum BoxMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case perLine
    case block
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return L("Нет")
        case .perLine: return L("Под строками")
        case .block: return L("Общая")
        }
    }
}

/// A subtitle style preset. Sizes are in pixels for a 1080p frame (measured on the short side)
/// and scale proportionally with the video resolution.
public struct SubtitlePreset: Codable, Hashable, Identifiable, Sendable {
    /// Oswald ships with the app (SIL OFL), so the built-in presets look the same on every Mac, Cyrillic included:
    /// a narrow dense sans like Stapel, which was the default before and is a paid font.
    public static let defaultFontFamily = "Oswald"
    public static let referenceShortSide: Double = 1080

    public var id: UUID
    public var name: String

    // Font
    public var fontFamily: String
    public var fontFace: String
    public var fontSize: Double
    public var letterSpacing: Double
    /// Extra space between lines (can be negative).
    public var lineGap: Double

    /// Synthetic slant in degrees (positive leans right); works with any font.
    public var slant: Double

    // Text
    public var caseMode: TextCaseMode
    /// ВСЕ ЗАГЛАВНЫЕ on top of the case mode (used for emphasis on words).
    public var uppercase: Bool
    public var textColor: RGBAColor

    // Highlight: a rounded plate behind each word (popular Reels style, mostly used on single words)
    public var highlightEnabled: Bool
    public var highlightColor: RGBAColor

    // Outline
    public var outlineEnabled: Bool
    public var outlineColor: RGBAColor
    public var outlineWidth: Double

    // Shadow
    public var shadowEnabled: Bool
    public var shadowColor: RGBAColor
    public var shadowBlur: Double
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double

    // Background box
    public var boxMode: BoxMode
    public var boxColor: RGBAColor
    public var boxPadding: Double
    public var boxCornerRadius: Double

    // Position & layout
    /// Horizontal anchor of the text block, 0...1 of the frame width: the left edge, the center or the right
    /// edge depending on `alignment`.
    public var positionX: Double
    /// Vertical anchor of the text block, 0...1 of the frame height: top, center or bottom per `anchor`.
    public var positionY: Double
    public var anchor: VerticalAnchor
    /// Max width of the text block, fraction of the frame width.
    public var maxWidth: Double
    public var alignment: TextAlignmentMode
    /// 1 = single line, 2-3 = multi-line subtitles.
    public var maxLines: Int
    /// 0 = no limit.
    public var maxWordsPerCue: Int
    public var maxCueDuration: Double

    public init(
        id: UUID = UUID(),
        name: String,
        fontFamily: String = SubtitlePreset.defaultFontFamily,
        fontFace: String = "Bold",
        fontSize: Double = 72,
        letterSpacing: Double = 0,
        lineGap: Double = 0,
        slant: Double = 0,
        caseMode: TextCaseMode = .original,
        uppercase: Bool = false,
        textColor: RGBAColor = .white,
        highlightEnabled: Bool = false,
        highlightColor: RGBAColor = RGBAColor(r: 1, g: 0.84, b: 0.04),
        outlineEnabled: Bool = true,
        outlineColor: RGBAColor = .black,
        outlineWidth: Double = 5,
        shadowEnabled: Bool = false,
        shadowColor: RGBAColor = RGBAColor.black.withAlpha(0.6),
        shadowBlur: Double = 8,
        shadowOffsetX: Double = 0,
        shadowOffsetY: Double = 4,
        boxMode: BoxMode = .none,
        boxColor: RGBAColor = RGBAColor.black.withAlpha(0.6),
        boxPadding: Double = 16,
        boxCornerRadius: Double = 14,
        positionX: Double = 0.5,
        positionY: Double = 0.75,
        anchor: VerticalAnchor = .center,
        maxWidth: Double = 0.86,
        alignment: TextAlignmentMode = .center,
        maxLines: Int = 2,
        maxWordsPerCue: Int = 0,
        maxCueDuration: Double = 5
    ) {
        self.id = id
        self.name = name
        self.fontFamily = fontFamily
        self.fontFace = fontFace
        self.fontSize = fontSize
        self.letterSpacing = letterSpacing
        self.lineGap = lineGap
        self.slant = slant
        self.caseMode = caseMode
        self.uppercase = uppercase
        self.textColor = textColor
        self.highlightEnabled = highlightEnabled
        self.highlightColor = highlightColor
        self.outlineEnabled = outlineEnabled
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
        self.shadowEnabled = shadowEnabled
        self.shadowColor = shadowColor
        self.shadowBlur = shadowBlur
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.boxMode = boxMode
        self.boxColor = boxColor
        self.boxPadding = boxPadding
        self.boxCornerRadius = boxCornerRadius
        self.positionX = positionX
        self.positionY = positionY
        self.anchor = anchor
        self.maxWidth = maxWidth
        self.alignment = alignment
        self.maxLines = maxLines
        self.maxWordsPerCue = maxWordsPerCue
        self.maxCueDuration = maxCueDuration
    }

    /// Settings that change how words are grouped into subtitles. When they change, cues are rebuilt.
    public var layoutKey: String {
        [
            fontFamily, fontFace,
            String(format: "%.1f", fontSize), String(format: "%.1f", letterSpacing),
            String(format: "%.3f", maxWidth), String(maxLines), String(maxWordsPerCue),
            String(format: "%.2f", maxCueDuration), caseMode.rawValue, uppercase ? "UP" : "-",
            outlineEnabled ? String(format: "%.1f", outlineWidth) : "-",
            boxMode == .none ? "-" : String(format: "%.1f", boxPadding),
        ].joined(separator: "|")
    }

    public func duplicated(name: String) -> SubtitlePreset {
        var copy = self
        copy.id = UUID()
        copy.name = name
        return copy
    }

    // MARK: Built-in presets

    /// The built-in presets keep these identifiers on every Mac, so «Восстановить стандартные пресеты» finds them even
    /// after they were renamed or changed.
    public static let builtInIDs: [UUID] = [
        "5B11E000-0000-4000-8000-000000000001", "5B11E000-0000-4000-8000-000000000002",
        "5B11E000-0000-4000-8000-000000000003", "5B11E000-0000-4000-8000-000000000004",
    ].map { UUID(uuidString: $0)! }

    /// Every name a built-in preset has had, in both languages: a preset saved under such a name by an older version
    /// (with an identifier of its own) is that built-in preset.
    static let builtInNames: [Set<String>] = [
        ["Reels / Shorts — 2 строки", "Reels / Shorts — 2 lines"],
        ["Reels / Shorts — 1 строка", "Reels / Shorts — 1 line"],
        ["YouTube — классические", "YouTube — classic"],
        ["С подложкой", "With Background", "Плашка", "Plate"],
    ]

    public static var builtIn: [SubtitlePreset] {
        [
            SubtitlePreset(
                id: builtInIDs[0],
                name: L("Reels / Shorts — 2 строки"),
                fontFace: "Bold", fontSize: 76,
                outlineWidth: 5,
                positionY: 0.72, anchor: .center, maxWidth: 0.84, maxLines: 2
            ),
            SubtitlePreset(
                id: builtInIDs[1],
                name: L("Reels / Shorts — 1 строка"),
                fontFace: "Bold", fontSize: 84,
                outlineWidth: 6,
                positionY: 0.70, anchor: .center, maxWidth: 0.88, maxLines: 1, maxWordsPerCue: 4
            ),
            SubtitlePreset(
                id: builtInIDs[2],
                name: L("YouTube — классические"),
                fontFace: "Medium", fontSize: 52,
                outlineWidth: 3.5,
                shadowEnabled: true,
                positionY: 0.92, anchor: .bottom, maxWidth: 0.8, maxLines: 2, maxCueDuration: 6
            ),
            SubtitlePreset(
                id: builtInIDs[3],
                name: L("С подложкой"),
                fontFace: "Medium", fontSize: 56,
                outlineEnabled: false,
                boxMode: .perLine, boxColor: RGBAColor.black.withAlpha(0.7),
                positionY: 0.88, anchor: .bottom, maxWidth: 0.82, maxLines: 2
            ),
        ]
    }

    /// The presets after «Восстановить стандартные пресеты»: every built-in preset gets its original look back in its
    /// place (found by identifier, or by name when an older version saved it under another identifier), a missing one
    /// comes back at the end. The person's own presets stay as they are.
    public static func restoringBuiltIn(in presets: [SubtitlePreset]) -> [SubtitlePreset] {
        var result = presets
        let ids = Set(builtInIDs)
        var used = Set<Int>()
        for (number, original) in builtIn.enumerated() {
            let names = builtInNames[number].union([original.name])
            if let index = result.firstIndex(where: { $0.id == original.id }) {
                result[index] = original
                used.insert(index)
            } else if let index = result.indices.first(where: {
                !used.contains($0) && !ids.contains(result[$0].id) && names.contains(result[$0].name)
            }) {
                // Saved by an older version: the identifier stays, so videos styled with it still find it.
                var restored = original
                restored.id = result[index].id
                result[index] = restored
                used.insert(index)
            } else {
                result.append(original)
                used.insert(result.count - 1)
            }
        }
        return result
    }

    // MARK: Codable with defaults (older preset files keep working when fields are added)

    enum CodingKeys: String, CodingKey {
        case id, name, fontFamily, fontFace, fontSize, letterSpacing, lineGap, slant, caseMode, uppercase, textColor
        case highlightEnabled, highlightColor
        case outlineEnabled, outlineColor, outlineWidth
        case shadowEnabled, shadowColor, shadowBlur, shadowOffsetX, shadowOffsetY
        case boxMode, boxColor, boxPadding, boxCornerRadius
        case positionX, positionY, anchor, maxWidth, alignment, maxLines, maxWordsPerCue, maxCueDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitlePreset(name: "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? L("Пресет")
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        fontFace = try c.decodeIfPresent(String.self, forKey: .fontFace) ?? d.fontFace
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? d.letterSpacing
        lineGap = try c.decodeIfPresent(Double.self, forKey: .lineGap) ?? d.lineGap
        slant = try c.decodeIfPresent(Double.self, forKey: .slant) ?? d.slant
        caseMode = try c.decodeIfPresent(TextCaseMode.self, forKey: .caseMode) ?? d.caseMode
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? d.uppercase
        textColor = try c.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? d.textColor
        highlightEnabled = try c.decodeIfPresent(Bool.self, forKey: .highlightEnabled) ?? d.highlightEnabled
        highlightColor = try c.decodeIfPresent(RGBAColor.self, forKey: .highlightColor) ?? d.highlightColor
        outlineEnabled = try c.decodeIfPresent(Bool.self, forKey: .outlineEnabled) ?? d.outlineEnabled
        outlineColor = try c.decodeIfPresent(RGBAColor.self, forKey: .outlineColor) ?? d.outlineColor
        outlineWidth = try c.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? d.outlineWidth
        shadowEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? d.shadowEnabled
        shadowColor = try c.decodeIfPresent(RGBAColor.self, forKey: .shadowColor) ?? d.shadowColor
        shadowBlur = try c.decodeIfPresent(Double.self, forKey: .shadowBlur) ?? d.shadowBlur
        shadowOffsetX = try c.decodeIfPresent(Double.self, forKey: .shadowOffsetX) ?? d.shadowOffsetX
        shadowOffsetY = try c.decodeIfPresent(Double.self, forKey: .shadowOffsetY) ?? d.shadowOffsetY
        boxMode = try c.decodeIfPresent(BoxMode.self, forKey: .boxMode) ?? d.boxMode
        boxColor = try c.decodeIfPresent(RGBAColor.self, forKey: .boxColor) ?? d.boxColor
        boxPadding = try c.decodeIfPresent(Double.self, forKey: .boxPadding) ?? d.boxPadding
        boxCornerRadius = try c.decodeIfPresent(Double.self, forKey: .boxCornerRadius) ?? d.boxCornerRadius
        positionX = try c.decodeIfPresent(Double.self, forKey: .positionX) ?? d.positionX
        positionY = try c.decodeIfPresent(Double.self, forKey: .positionY) ?? d.positionY
        anchor = try c.decodeIfPresent(VerticalAnchor.self, forKey: .anchor) ?? d.anchor
        maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth) ?? d.maxWidth
        alignment = try c.decodeIfPresent(TextAlignmentMode.self, forKey: .alignment) ?? d.alignment
        maxLines = try c.decodeIfPresent(Int.self, forKey: .maxLines) ?? d.maxLines
        maxWordsPerCue = try c.decodeIfPresent(Int.self, forKey: .maxWordsPerCue) ?? d.maxWordsPerCue
        maxCueDuration = try c.decodeIfPresent(Double.self, forKey: .maxCueDuration) ?? d.maxCueDuration
    }
}
