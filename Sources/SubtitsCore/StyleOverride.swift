import Foundation

/// Style changes on top of the preset. Every property is optional: nil means "inherit".
/// Applied in layers: preset → group → subtitle → word.
public struct StyleOverride: Codable, Hashable, Sendable {
    public var fontFamily: String?
    public var fontFace: String?
    public var fontSize: Double?
    public var letterSpacing: Double?
    public var lineGap: Double?
    public var slant: Double?
    public var caseMode: TextCaseMode?
    public var uppercase: Bool?
    public var textColor: RGBAColor?
    public var highlightEnabled: Bool?
    public var highlightColor: RGBAColor?
    public var outlineEnabled: Bool?
    public var outlineColor: RGBAColor?
    public var outlineWidth: Double?
    public var shadowEnabled: Bool?
    public var shadowColor: RGBAColor?
    public var shadowBlur: Double?
    public var shadowOffsetX: Double?
    public var shadowOffsetY: Double?
    public var boxMode: BoxMode?
    public var boxColor: RGBAColor?
    public var boxPadding: Double?
    public var boxCornerRadius: Double?
    public var positionX: Double?
    public var positionY: Double?
    public var anchor: VerticalAnchor?
    public var alignment: TextAlignmentMode?
    public var maxWidth: Double?
    public var maxLines: Int?

    public init() {}

    public var isEmpty: Bool { self == StyleOverride() }

    /// The style with these overrides applied.
    public func applied(to base: SubtitlePreset) -> SubtitlePreset {
        var result = base
        if let fontFamily { result.fontFamily = fontFamily }
        if let fontFace { result.fontFace = fontFace }
        if let fontSize { result.fontSize = fontSize }
        if let letterSpacing { result.letterSpacing = letterSpacing }
        if let lineGap { result.lineGap = lineGap }
        if let slant { result.slant = slant }
        if let caseMode { result.caseMode = caseMode }
        if let uppercase { result.uppercase = uppercase }
        if let textColor { result.textColor = textColor }
        if let highlightEnabled { result.highlightEnabled = highlightEnabled }
        if let highlightColor { result.highlightColor = highlightColor }
        if let outlineEnabled { result.outlineEnabled = outlineEnabled }
        if let outlineColor { result.outlineColor = outlineColor }
        if let outlineWidth { result.outlineWidth = outlineWidth }
        if let shadowEnabled { result.shadowEnabled = shadowEnabled }
        if let shadowColor { result.shadowColor = shadowColor }
        if let shadowBlur { result.shadowBlur = shadowBlur }
        if let shadowOffsetX { result.shadowOffsetX = shadowOffsetX }
        if let shadowOffsetY { result.shadowOffsetY = shadowOffsetY }
        if let boxMode { result.boxMode = boxMode }
        if let boxColor { result.boxColor = boxColor }
        if let boxPadding { result.boxPadding = boxPadding }
        if let boxCornerRadius { result.boxCornerRadius = boxCornerRadius }
        if let positionX { result.positionX = positionX }
        if let positionY { result.positionY = positionY }
        if let anchor { result.anchor = anchor }
        if let alignment { result.alignment = alignment }
        if let maxWidth { result.maxWidth = maxWidth }
        if let maxLines { result.maxLines = maxLines }
        return result
    }

    /// These overrides with `other` on top (its non-nil values win).
    public func merging(_ other: StyleOverride) -> StyleOverride {
        var result = self
        if let value = other.fontFamily { result.fontFamily = value }
        if let value = other.fontFace { result.fontFace = value }
        if let value = other.fontSize { result.fontSize = value }
        if let value = other.letterSpacing { result.letterSpacing = value }
        if let value = other.lineGap { result.lineGap = value }
        if let value = other.slant { result.slant = value }
        if let value = other.caseMode { result.caseMode = value }
        if let value = other.uppercase { result.uppercase = value }
        if let value = other.textColor { result.textColor = value }
        if let value = other.highlightEnabled { result.highlightEnabled = value }
        if let value = other.highlightColor { result.highlightColor = value }
        if let value = other.outlineEnabled { result.outlineEnabled = value }
        if let value = other.outlineColor { result.outlineColor = value }
        if let value = other.outlineWidth { result.outlineWidth = value }
        if let value = other.shadowEnabled { result.shadowEnabled = value }
        if let value = other.shadowColor { result.shadowColor = value }
        if let value = other.shadowBlur { result.shadowBlur = value }
        if let value = other.shadowOffsetX { result.shadowOffsetX = value }
        if let value = other.shadowOffsetY { result.shadowOffsetY = value }
        if let value = other.boxMode { result.boxMode = value }
        if let value = other.boxColor { result.boxColor = value }
        if let value = other.boxPadding { result.boxPadding = value }
        if let value = other.boxCornerRadius { result.boxCornerRadius = value }
        if let value = other.positionX { result.positionX = value }
        if let value = other.positionY { result.positionY = value }
        if let value = other.anchor { result.anchor = value }
        if let value = other.alignment { result.alignment = value }
        if let value = other.maxWidth { result.maxWidth = value }
        if let value = other.maxLines { result.maxLines = value }
        return result
    }

    /// Every property of a full style, as overrides (used by "copy style").
    public static func capturing(_ style: SubtitlePreset) -> StyleOverride {
        var override = StyleOverride()
        override.fontFamily = style.fontFamily
        override.fontFace = style.fontFace
        override.fontSize = style.fontSize
        override.letterSpacing = style.letterSpacing
        override.lineGap = style.lineGap
        override.slant = style.slant
        override.caseMode = style.caseMode
        override.uppercase = style.uppercase
        override.textColor = style.textColor
        override.highlightEnabled = style.highlightEnabled
        override.highlightColor = style.highlightColor
        override.outlineEnabled = style.outlineEnabled
        override.outlineColor = style.outlineColor
        override.outlineWidth = style.outlineWidth
        override.shadowEnabled = style.shadowEnabled
        override.shadowColor = style.shadowColor
        override.shadowBlur = style.shadowBlur
        override.shadowOffsetX = style.shadowOffsetX
        override.shadowOffsetY = style.shadowOffsetY
        override.boxMode = style.boxMode
        override.boxColor = style.boxColor
        override.boxPadding = style.boxPadding
        override.boxCornerRadius = style.boxCornerRadius
        override.positionX = style.positionX
        override.positionY = style.positionY
        override.anchor = style.anchor
        override.alignment = style.alignment
        override.maxWidth = style.maxWidth
        override.maxLines = style.maxLines
        return override
    }

    /// Properties that make sense for a single word (no layout, shadow or box).
    public var wordLevel: StyleOverride {
        var result = StyleOverride()
        result.fontFamily = fontFamily
        result.fontFace = fontFace
        result.fontSize = fontSize
        result.letterSpacing = letterSpacing
        result.slant = slant
        result.uppercase = uppercase
        result.textColor = textColor
        result.highlightEnabled = highlightEnabled
        result.highlightColor = highlightColor
        result.outlineEnabled = outlineEnabled
        result.outlineColor = outlineColor
        result.outlineWidth = outlineWidth
        return result
    }
}

/// Subtitles that share one style (e.g. a second speaker at the top of the frame).
public struct SubtitleGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var color: RGBAColor
    public var style: StyleOverride

    public init(id: UUID = UUID(), name: String, color: RGBAColor, style: StyleOverride = StyleOverride()) {
        self.id = id
        self.name = name
        self.color = color
        self.style = style
    }

    /// Tag colors offered for new groups.
    public static let palette: [RGBAColor] = [
        RGBAColor(r: 0.0, g: 0.48, b: 1.0), RGBAColor(r: 1.0, g: 0.58, b: 0.0), RGBAColor(r: 0.2, g: 0.78, b: 0.35),
        RGBAColor(r: 0.69, g: 0.32, b: 0.87), RGBAColor(r: 1.0, g: 0.18, b: 0.33), RGBAColor(r: 0.35, g: 0.78, b: 0.98),
        RGBAColor(r: 1.0, g: 0.8, b: 0.0), RGBAColor(r: 0.64, g: 0.52, b: 0.37),
    ]
}
