import XCTest
import CoreGraphics
import ImageIO
@testable import SublineCore

/// The export pipeline on a short video made here with the bundled ffmpeg: subtitles burned into MP4 and written as SRT.
final class ExportPipelineTests: XCTestCase {
    /// The package root (Tests/SublineCoreTests/ExportPipelineTests.swift → two folders up).
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let ffmpeg = root.appendingPathComponent("Vendor/ffmpeg/ffmpeg")

    private var work: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.ffmpeg.path), "no Vendor/ffmpeg (scripts/fetch_ffmpeg.sh)")
        setenv("SUBLINE_FFMPEG", Self.ffmpeg.path, 1)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("subline-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    /// A dark 2-second vertical video with a tone.
    static func makeVideo(at url: URL, seconds: Double = 2) async throws {
        _ = try await FFmpeg.run([
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=0x203040:s=360x640:r=30:d=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path,
        ])
    }

    /// Share of bright pixels (text is white) in the lower half of a frame at `time`.
    static func brightShare(of video: URL, at time: Double, in work: URL) async throws -> Double {
        let png = work.appendingPathComponent("frame-\(time).png")
        _ = try await FFmpeg.run(["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", String(time), "-i", video.path,
                                  "-frames:v", "1", png.path])
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bright = 0, total = 0
        // Rows of the bitmap from the top: the lower half of the frame.
        for y in (height / 2)..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                total += 1
                if pixels[i] > 200 && pixels[i + 1] > 200 && pixels[i + 2] > 200 { bright += 1 }
            }
        }
        return Double(bright) / Double(max(1, total))
    }

    func testBurnedSubtitlesShowOnlyWhileTheyLast() async throws {
        let video = work.appendingPathComponent("source.mp4")
        try await Self.makeVideo(at: video)
        let info = try await FFmpeg.probe(video)
        XCTAssertTrue(info.hasVideo)
        XCTAssertEqual(info.duration, 2, accuracy: 0.2)

        var preset = SubtitlePreset.builtIn[1]
        preset.positionY = 0.75
        let cues = [Cue(start: 0.2, end: 1.2, text: "Наше дело")]
        let output = work.appendingPathComponent("out.mp4")
        var stages: [String] = []
        try await Exporter.exportVideo(info: info, cues: cues, preset: preset, format: .mp4H264, output: output) { stage, _ in
            stages.append(stage)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let result = try await FFmpeg.probe(output)
        XCTAssertTrue(result.hasVideo)
        XCTAssertTrue(result.hasAudio)
        XCTAssertEqual(result.duration, info.duration, accuracy: 0.2)
        XCTAssertFalse(stages.isEmpty)

        let during = try await Self.brightShare(of: output, at: 0.7, in: work)
        let after = try await Self.brightShare(of: output, at: 1.7, in: work)
        XCTAssertGreaterThan(during, 0.003, "white text is burned in while the subtitle lasts")
        XCTAssertLessThan(after, 0.0005, "nothing is drawn after it ends")
    }

    func testSRTHasTimesAndOneLinePerSubtitleInOneLineStyle() {
        let renderer = CueRenderer(preset: SubtitlePreset.builtIn[1], canvas: CGSize(width: 1080, height: 1920))
        let srt = Exporter.srt(cues: [Cue(start: 0.2, end: 1.25, text: "Наше\nдело"), Cue(start: 61, end: 62.5, text: "второй")],
                               renderer: renderer)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,200 --> 00:00:01,250\n"), srt)
        XCTAssertTrue(srt.contains("\n2\n00:01:01,000 --> 00:01:02,500\n"), srt)
        let firstText = srt.components(separatedBy: "\n")[2]
        XCTAssertFalse(firstText.isEmpty)
        XCTAssertEqual(srt.components(separatedBy: "\n")[3], "", "one line: the break typed by hand is a space")
    }
}
