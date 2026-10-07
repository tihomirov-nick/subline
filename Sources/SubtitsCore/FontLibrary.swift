import Foundation
import CoreText
import CoreGraphics

public struct FontFaceInfo: Hashable, Sendable {
    public let postScriptName: String
    public let styleName: String
    /// CoreText weight trait, -1...1 (0 = regular, 0.4 = bold).
    public let weight: Double
    public let isItalic: Bool
}

public enum FontError: LocalizedError {
    case notAFont(String)

    public var errorDescription: String? {
        switch self {
        case .notAFont(let name): return L("Файл «%@» не является шрифтом (нужен .ttf, .otf или .ttc).", "\(name)")
        }
    }
}

/// Font discovery and registration. Fonts shipped with the app (Contents/Resources/Fonts) and fonts added
/// by the user (~/Library/Application Support/Subtits/Fonts) are registered for this process only.
public enum FontLibrary {
    public static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont"]

    private static let lock = NSLock()
    private static var registeredFiles = Set<String>()
    private static var appFamilies = Set<String>()

    /// Registers bundled and user fonts. Safe to call more than once.
    public static func registerAppFonts() {
        if let dir = AppPaths.bundledFontsDir {
            registerFonts(inDirectory: dir)
        }
        registerFonts(inDirectory: AppPaths.userFontsDir)
    }

    @discardableResult
    public static func registerFonts(inDirectory dir: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var families: [String] = []
        for case let url as URL in enumerator where fontExtensions.contains(url.pathExtension.lowercased()) {
            families += (try? registerFont(at: url)) ?? []
        }
        return families
    }

    @discardableResult
    public static func registerFont(at url: URL) throws -> [String] {
        let families = familyNames(inFontFile: url)
        guard !families.isEmpty else { throw FontError.notAFont(url.lastPathComponent) }
        lock.lock()
        let alreadyRegistered = registeredFiles.contains(url.path)
        lock.unlock()
        if !alreadyRegistered {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // "Already registered" (e.g. the same font is installed in the system) is fine.
                _ = error?.takeRetainedValue()
            }
            lock.lock()
            registeredFiles.insert(url.path)
            lock.unlock()
        }
        lock.lock()
        appFamilies.formUnion(families)
        lock.unlock()
        return families
    }

    public static func familyNames(inFontFile url: URL) -> [String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        var names: [String] = []
        for descriptor in descriptors {
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
               !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Copies a font file into the user fonts folder and registers it. Returns the family names it contains.
    @discardableResult
    public static func importFont(from url: URL) throws -> [String] {
        let families = familyNames(inFontFile: url)
        guard !families.isEmpty else { throw FontError.notAFont(url.lastPathComponent) }
        let destination = AppPaths.userFontsDir.appendingPathComponent(url.lastPathComponent)
        if destination.standardizedFileURL != url.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destination.path) {
                CTFontManagerUnregisterFontsForURL(destination as CFURL, .process, nil)
                lock.lock()
                registeredFiles.remove(destination.path)
                lock.unlock()
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return try registerFont(at: destination)
    }

    /// Families that come from the app's own fonts (bundled + imported), e.g. "Stapel".
    public static var appFamilyNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return appFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// All font families available to the app (system + registered).
    public static func allFamilyNames() -> [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func isAvailable(family: String) -> Bool {
        !faces(of: family).isEmpty
    }

    /// Faces (styles) of a family, sorted upright first, then by weight.
    public static func faces(of family: String) -> [FontFaceInfo] {
        let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let mandatory: NSSet = [kCTFontFamilyNameAttribute as String]
        guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory as CFSet) as? [CTFontDescriptor] else {
            return []
        }
        var result: [FontFaceInfo] = []
        var seen = Set<String>()
        for match in matches {
            guard let familyName = CTFontDescriptorCopyAttribute(match, kCTFontFamilyNameAttribute) as? String,
                  familyName == family,
                  let psName = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) as? String,
                  !seen.contains(psName) else { continue }
            seen.insert(psName)
            let style = CTFontDescriptorCopyAttribute(match, kCTFontStyleNameAttribute) as? String ?? "Regular"
            let traits = CTFontDescriptorCopyAttribute(match, kCTFontTraitsAttribute) as? [CFString: Any]
            let weight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let italic = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
            result.append(FontFaceInfo(postScriptName: psName, styleName: style, weight: weight, isItalic: italic))
        }
        return result.sorted {
            if $0.isItalic != $1.isItalic { return !$0.isItalic }
            return $0.weight < $1.weight
        }
    }

    public struct Resolved {
        public let font: CTFont
        public let isFallback: Bool
        public let familyName: String
    }

    private static var cyrillicCache: [String: Bool] = [:]

    /// The family has Russian letters (otherwise macOS substitutes another font for them).
    public static func supportsCyrillic(family: String) -> Bool {
        lock.lock()
        if let cached = cyrillicCache[family] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var result = false
        if let psName = postScriptName(family: family, face: "Regular") {
            let font = CTFontCreateWithName(psName as CFString, 12, nil)
            let characters = Array("АБВЖЯабвжяё".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            result = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        }
        lock.lock()
        cyrillicCache[family] = result
        lock.unlock()
        return result
    }

    /// Creates the font for a preset. Falls back to a system font with Cyrillic when the family is missing.
    public static func resolve(family: String, face: String, size: CGFloat) -> Resolved {
        if let psName = postScriptName(family: family, face: face) {
            return Resolved(font: CTFontCreateWithName(psName as CFString, size, nil), isFallback: false, familyName: family)
        }
        for fallback in ["Montserrat", "Arial", "Helvetica Neue", "Helvetica"] {
            if let psName = postScriptName(family: fallback, face: face) {
                return Resolved(font: CTFontCreateWithName(psName as CFString, size, nil), isFallback: true, familyName: fallback)
            }
        }
        let system = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return Resolved(font: system, isFallback: true, familyName: "System")
    }

    static func postScriptName(family: String, face: String) -> String? {
        let faces = faces(of: family)
        guard !faces.isEmpty else { return nil }
        if let exact = faces.first(where: { $0.styleName.caseInsensitiveCompare(face) == .orderedSame }) {
            return exact.postScriptName
        }
        let wantsItalic = face.lowercased().contains("italic")
        let target = weight(forStyleName: face)
        let sameSlant = faces.filter { $0.isItalic == wantsItalic }
        let pool = sameSlant.isEmpty ? faces : sameSlant
        return pool.min(by: { abs($0.weight - target) < abs($1.weight - target) })?.postScriptName
    }

    /// Approximate CoreText weight for a style name ("Bold" -> 0.4).
    public static func weight(forStyleName name: String) -> Double {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        if n.contains("black") || n.contains("heavy") { return 0.62 }
        if n.contains("extrabold") || n.contains("ultrabold") { return 0.56 }
        if n.contains("semibold") || n.contains("demibold") { return 0.3 }
        if n.contains("bold") { return 0.4 }
        if n.contains("medium") { return 0.23 }
        if n.contains("extralight") || n.contains("ultralight") || n.contains("thin") || n.contains("hairline") { return -0.6 }
        if n.contains("light") { return -0.4 }
        return 0
    }
}
