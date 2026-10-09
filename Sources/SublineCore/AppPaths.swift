import Foundation

/// File system locations used by the app.
public enum AppPaths {
    public static let appName = "Subline"

    /// ~/Library/Application Support/Subline
    public static var appSupport: URL { ensureDir(supportURL) }

    /// The folder of Subtits (the app's earlier name) becomes Subline's on first use: presets, models, fonts and saved
    /// transcripts move with it. The old name stays as a link to the new folder, for apps that still look for the
    /// shared Whisper models in Subtits/Models (older Slovo).
    private static let supportURL: URL = {
        // Tests keep their presets, saved subtitles and models apart from the real ones.
        if let path = ProcessInfo.processInfo.environment["SUBLINE_SUPPORT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(appName, isDirectory: true)
        let old = base.appendingPathComponent(FormerName.folderName, isDirectory: true)
        let files = FileManager.default
        // A link left by an earlier launch, or no Subtits at all: nothing to take over.
        guard (try? files.attributesOfItem(atPath: old.path))?[.type] as? FileAttributeType == .typeDirectory else {
            return url
        }
        if !files.fileExists(atPath: url.path) {
            if (try? files.moveItem(at: old, to: url)) != nil {
                try? files.createSymbolicLink(atPath: old.path, withDestinationPath: appName)
            }
        } else {
            // Slovo may have created Subline/Models before Subline's first launch (when Subtits had no models):
            // what Subline does not have yet moves over, and an emptied Subtits becomes the link.
            moveMissing(from: old, to: url)
            if isEmpty(old) {
                try? files.removeItem(at: old)
                try? files.createSymbolicLink(atPath: old.path, withDestinationPath: appName)
            }
        }
        return url
    }()

    /// Moves the items of `source` that `target` does not have; folders present in both (Models) are merged the same
    /// way. A file present in both stays in `source`: the one in `target` wins.
    private static func moveMissing(from source: URL, to target: URL) {
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: source.path)) ?? [] where name != ".DS_Store" {
            let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
            if !files.fileExists(atPath: to.path) {
                try? files.moveItem(at: from, to: to)
            } else if isDirectory(from), isDirectory(to) {
                moveMissing(from: from, to: to)
                if isEmpty(from) { try? files.removeItem(at: from) }
            }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// No items except Finder's .DS_Store.
    private static func isEmpty(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]).allSatisfy { $0 == ".DS_Store" }
    }

    public static var modelsDir: URL { ensureDir(appSupport.appendingPathComponent("Models", isDirectory: true)) }
    public static var userFontsDir: URL { ensureDir(appSupport.appendingPathComponent("Fonts", isDirectory: true)) }
    public static var cacheDir: URL { ensureDir(appSupport.appendingPathComponent("Cache", isDirectory: true)) }
    /// Playable copies of videos that AVFoundation cannot open directly (MKV, WebM, AVI, ...).
    public static var proxiesDir: URL { ensureDir(cacheDir.appendingPathComponent("Proxies", isDirectory: true)) }
    public static var presetsFile: URL { appSupport.appendingPathComponent("presets.json") }

    /// A fresh temporary directory for one job (overlay frames, extracted audio, ...).
    public static func makeTempDir(_ prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(appName)-\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return ensureDir(dir)
    }

    @discardableResult
    static func ensureDir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Bundled resources

    /// Repository root when running from `.build` during development (directory containing Package.swift).
    static let devRoot: URL? = {
        var url = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<10 {
            guard let current = url else { return nil }
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            url = current.deletingLastPathComponent()
        }
        return nil
    }()

    /// Directory with fonts shipped inside the app (Contents/Resources/Fonts), or `Fonts/` in the repo during development.
    public static var bundledFontsDir: URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = devRoot?.appendingPathComponent("Fonts", isDirectory: true),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    /// Silero VAD model shipped with the app.
    public static var vadModelURL: URL? {
        let name = "ggml-silero-v6.2.0.bin"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = devRoot?.appendingPathComponent("Resources").appendingPathComponent(name),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    /// The ffmpeg binary: bundled helper first, then the development copy, then a system install.
    public static var ffmpegURL: URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["SUBLINE_FFMPEG"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg"))
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("ffmpeg"))
        }
        if let root = devRoot {
            candidates.append(root.appendingPathComponent("Vendor/ffmpeg/ffmpeg"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
