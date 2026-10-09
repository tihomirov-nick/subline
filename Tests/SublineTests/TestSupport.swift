import XCTest
import AppKit
import SwiftUI
@testable import Subline
@testable import SublineCore

/// One setup for every test of the window: Subline's data in a temporary folder (the real presets and saved subtitles
/// stay untouched), no sounds, no menu bar icon, no Dock icon, nothing recognized by itself.
@MainActor
enum TestEnvironment {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let ffmpeg = root.appendingPathComponent("Vendor/ffmpeg/ffmpeg")
    static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("subline-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    /// Pictures of the views: SUBLINE_TEST_RENDERS when set, otherwise the temporary folder.
    static var renders: URL {
        if let path = ProcessInfo.processInfo.environment["SUBLINE_TEST_RENDERS"] { return URL(fileURLWithPath: path) }
        return folder.appendingPathComponent("renders", isDirectory: true)
    }
    private static var ready = false

    static func setUp() {
        guard !ready else { return }
        ready = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("SUBLINE_SUPPORT_DIR", folder.appendingPathComponent("Support").path, 1)
        setenv("SUBLINE_FFMPEG", ffmpeg.path, 1)
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: SoundEffects.enabledKey)
        defaults.set(false, forKey: MenuBarIcon.enabledKey)
        defaults.set(false, forKey: "autoTranscribe")
        for key in ["lastMediaPath", "lastMediaTime", "selectedPreset", "recentMedia", "lastExportPath", "language"] {
            defaults.removeObject(forKey: key)
        }
        // The fonts the app ships (Contents/Resources/Fonts in the app), as the app registers them.
        FontLibrary.registerFonts(inDirectory: root.appendingPathComponent("Fonts"))
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    static var hasFFmpeg: Bool { FileManager.default.isExecutableFile(atPath: ffmpeg.path) }

    /// A dark vertical video with a tone, made with the bundled ffmpeg. The name goes into the file's metadata: the
    /// saved work is found by the content of a file, and every test video is a video of its own.
    static func makeVideo(named name: String, seconds: Double = 3, silent: Bool = false) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let audio = silent ? "anullsrc=r=44100:cl=mono" : "sine=frequency=440:duration=\(seconds)"
        _ = try await FFmpeg.run([
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=0x203040:s=360x640:r=30:d=\(seconds)",
            "-f", "lavfi", "-i", audio,
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-t", "\(seconds)", "-shortest",
            "-metadata", "comment=\(name)", url.path,
        ])
        return url
    }

    /// Recognized words for "раз два наше | дело простое. Третий субтитр тут".
    static var transcript: Transcript {
        let words = [("раз", 0.0, 0.3), ("два", 0.35, 0.6), ("наше", 0.7, 1.0), ("дело", 1.4, 1.7), ("простое.", 1.75, 2.1),
                     ("Третий", 2.2, 2.45), ("субтитр", 2.5, 2.7), ("тут", 2.72, 2.9)]
            .map { Word(text: $0.0, start: $0.1, end: $0.2) }
        return Transcript(language: "ru", modelName: "test", duration: 3,
                          segments: [TranscriptSegment(start: 0, end: 2.9, text: "", words: words)])
    }

    /// Waits while the main actor keeps running the model's work.
    static func wait(_ what: String, timeout: TimeInterval = 20, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Draws a view in a window that is never shown and writes it as PNG.
    @discardableResult
    static func render<V: View>(_ view: V, size: CGSize, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = renders.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        window.close()
        return url
    }
}
