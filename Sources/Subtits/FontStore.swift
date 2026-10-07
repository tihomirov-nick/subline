import Foundation
import CoreText
import SubtitsCore

/// Installs fonts from the catalog (one click) and fonts added as files.
@MainActor
final class FontStore: ObservableObject {
    @Published private(set) var installing: [String: Double] = [:]
    @Published private(set) var installedIDs: Set<String> = []
    @Published var lastError: String?
    /// Fonts loaded only for previews in the library (not installed, not registered).
    @Published private(set) var previews: [String: CTFontDescriptor] = [:]
    /// Called after fonts were added or removed (the app re-renders with the new fonts).
    var onChange: (() -> Void)?

    private var previewQueue: [CatalogFont] = []
    private var previewRequested = Set<String>()
    private var activePreviewLoads = 0

    init() {
        refresh()
    }

    func refresh() {
        installedIDs = Set(FontCatalog.fonts.filter(isInstalled).map(\.id))
    }

    private func isInstalled(_ font: CatalogFont) -> Bool {
        if font.bundled { return true }
        if font.isCommercial { return FontLibrary.isAvailable(family: font.family) }
        let files = font.downloads.map(\.name).filter { !$0.hasSuffix(".txt") }
        return files.allSatisfy { FileManager.default.fileExists(atPath: font.installDir.appendingPathComponent($0).path) }
    }

    /// Family name to use in a style (the registered name can differ slightly from the catalog name).
    func familyName(of font: CatalogFont) -> String {
        if FontLibrary.isAvailable(family: font.family) { return font.family }
        let files = (try? FileManager.default.contentsOfDirectory(at: font.installDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where FontLibrary.fontExtensions.contains(file.pathExtension.lowercased()) {
            if let family = FontLibrary.familyNames(inFontFile: file).first { return family }
        }
        return font.family
    }

    func install(_ font: CatalogFont) {
        guard installing[font.id] == nil, !font.downloads.isEmpty else { return }
        lastError = nil
        installing[font.id] = 0
        let downloads = font.downloads
        let destination = font.installDir
        Task {
            let staging = AppPaths.userFontsDir.appendingPathComponent(".\(font.id).part", isDirectory: true)
            do {
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                for (number, item) in downloads.enumerated() {
                    let (data, response) = try await URLSession.shared.data(from: item.url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                        throw URLError(.badServerResponse)
                    }
                    try data.write(to: staging.appendingPathComponent(item.name))
                    installing[font.id] = Double(number + 1) / Double(downloads.count)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staging, to: destination)
                FontLibrary.registerFonts(inDirectory: destination)
                installing[font.id] = nil
                refresh()
                onChange?()
            } catch {
                try? FileManager.default.removeItem(at: staging)
                installing[font.id] = nil
                lastError = L("Не удалось скачать «%@»: %@", "\(font.family)", "\(error.localizedDescription)")
            }
        }
    }

    func remove(_ font: CatalogFont) {
        guard !font.bundled else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: font.installDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where FontLibrary.fontExtensions.contains(file.pathExtension.lowercased()) {
            CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
        }
        try? FileManager.default.removeItem(at: font.installDir)
        refresh()
        onChange?()
    }

    // MARK: - Previews

    private static var previewDir: URL {
        let dir = AppPaths.cacheDir.appendingPathComponent("FontPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Loads the font file for a preview card: cached on disk, used through a descriptor without
    /// registering, so it does not appear in font lists until it is really installed.
    func requestPreview(_ font: CatalogFont) {
        guard previews[font.id] == nil, !previewRequested.contains(font.id), !installedIDs.contains(font.id),
              font.downloads.contains(where: { !$0.name.hasSuffix(".txt") }) else { return }
        previewRequested.insert(font.id)
        previewQueue.append(font)
        pumpPreviews()
    }

    private func pumpPreviews() {
        while activePreviewLoads < 4, !previewQueue.isEmpty {
            let font = previewQueue.removeFirst()
            activePreviewLoads += 1
            Task {
                if let descriptor = await Self.loadPreview(font) {
                    previews[font.id] = descriptor
                } else {
                    previewRequested.remove(font.id)
                }
                activePreviewLoads -= 1
                pumpPreviews()
            }
        }
    }

    private static func loadPreview(_ font: CatalogFont) async -> CTFontDescriptor? {
        guard let item = font.downloads.first(where: { !$0.name.hasSuffix(".txt") }) else { return nil }
        let file = previewDir.appendingPathComponent("\(font.id).\(URL(fileURLWithPath: item.name).pathExtension)")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let (data, response) = try? await URLSession.shared.data(from: item.url),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
            try? data.write(to: file)
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] else { return nil }
        // Prefer the regular style of the family for the sample.
        return descriptors.first {
            (CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String) == "Regular"
        } ?? descriptors.first
    }

    /// Adds font files chosen or dropped by the user (e.g. purchased Stapel). Returns the added families.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [String] {
        var families: [String] = []
        var failed: [String] = []
        for url in urls where FontLibrary.fontExtensions.contains(url.pathExtension.lowercased()) {
            do {
                families += try FontLibrary.importFont(from: url)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            lastError = L("Не удалось добавить: %@", "\(failed.joined(separator: ", "))")
        }
        refresh()
        onChange?()
        return families
    }
}
