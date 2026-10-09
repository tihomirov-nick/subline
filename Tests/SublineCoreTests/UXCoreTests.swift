import XCTest
import CoreText
@testable import SublineCore

/// The parts of the UX fixes that need no window: errors told for people, one time format, the default language and
/// font, silence, pictures, the standard presets and a cut of subtitles that can be cancelled.
final class UXCoreTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    // MARK: Errors

    func testFFmpegLinesAreReadForTheUsualCauses() {
        XCTAssertEqual(Problem.cause(inLog: "[out#0/mp4 @ 0x12d605050] Error opening output /x/.reels.part.mp4: Permission denied"), .noPermission)
        XCTAssertEqual(Problem.cause(inLog: "av_interleaved_write_frame(): No space left on device"), .noSpace)
        XCTAssertEqual(Problem.cause(inLog: "Error opening output file /Volumes/CD/a.mp4.\nRead-only file system"), .readOnly)
        XCTAssertEqual(Problem.cause(inLog: "/Users/a/notes.txt: Invalid data found when processing input"), .damaged)
        XCTAssertEqual(Problem.cause(inLog: "[mov,mp4] moov atom not found"), .damaged)
        XCTAssertEqual(Problem.cause(inLog: "/Users/a/gone.mp4: No such file or directory"), .notFound)
        XCTAssertEqual(Problem.cause(inLog: "Something else entirely"), .unknown)
    }

    func testFileSystemErrorsAreReadToo() {
        let output = URL(fileURLWithPath: "/tmp/out.srt")
        XCTAssertEqual(Problem.cause(of: CocoaError(.fileWriteNoPermission)).cause, .noPermission)
        XCTAssertEqual(Problem.cause(of: CocoaError(.fileWriteOutOfSpace)).cause, .noSpace)
        XCTAssertEqual(Problem.cause(of: CocoaError(.fileWriteVolumeReadOnly)).cause, .readOnly)
        XCTAssertEqual(Problem.cause(of: POSIXError(.EACCES)).cause, .noPermission)
        XCTAssertEqual(Problem.saving(CocoaError(.fileWriteNoPermission), output: output).title, L("Нет доступа к папке"))
    }

    func testExportProblemSaysWhatHappenedAndKeepsTheLogForDetails() {
        let log = "[out#0/mp4 @ 0x12d605050] Error opening output /Users/a/Locked/.reels.part.mp4: Permission denied"
        let output = URL(fileURLWithPath: "/Users/a/Locked/reels.mp4")
        let problem = Problem.exporting(MediaError.failed(log), output: output, source: nil)
        XCTAssertEqual(problem.title, L("Нет доступа к папке"))
        XCTAssertTrue(problem.message.contains("«Locked»"), problem.message)
        XCTAssertFalse(problem.message.contains("out#0"), "no raw log in the message")
        XCTAssertEqual(problem.details, log, "the log waits under Details")

        let unknown = Problem.exporting(MediaError.failed("Conversion failed!"), output: output, source: nil)
        XCTAssertEqual(unknown.title, L("Экспорт не удался"))
        XCTAssertEqual(unknown.details, "Conversion failed!")
    }

    func testOpeningProblems() {
        let file = URL(fileURLWithPath: "/Users/a/notes.mp4")
        let damaged = Problem.opening(MediaError.unreadable("/Users/a/notes.mp4: Invalid data found when processing input"), file: file)
        XCTAssertEqual(damaged.title, L("Файл не открылся"))
        XCTAssertTrue(damaged.message.contains("notes.mp4"))
        XCTAssertNotNil(damaged.details)
        let broken = Problem.opening(MediaError.ffmpegNotFound, file: file)
        XCTAssertEqual(broken.message, MediaError.ffmpegNotFound.localizedDescription, "what to do stays in the message")
        let picture = Problem.opening(MediaError.image, file: URL(fileURLWithPath: "/Users/a/photo.jpg"))
        XCTAssertEqual(picture.title, L("Картинки Subline не открывает"))
        XCTAssertNil(picture.details)
    }

    // MARK: Pictures and silence

    func testPicturesAreToldApartFromVideos() {
        XCTAssertTrue(FFmpeg.isPicture(URL(fileURLWithPath: "/a/photo.JPG")))
        XCTAssertTrue(FFmpeg.isPicture(URL(fileURLWithPath: "/a/shot.heic")))
        XCTAssertFalse(FFmpeg.isPicture(URL(fileURLWithPath: "/a/clip.mov")))
        XCTAssertFalse(FFmpeg.isPicture(URL(fileURLWithPath: "/a/voice.m4a")))
        XCTAssertTrue(FFmpeg.isPicture(probeOutput: "Input #0, png_pipe, from 'x':\n  Duration: N/A"))
        XCTAssertTrue(FFmpeg.isPicture(probeOutput: "Input #0, image2, from 'x.jpg':"))
        XCTAssertFalse(FFmpeg.isPicture(probeOutput: "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'x.mp4':"))
    }

    func testSilenceIsToldApartFromSound() {
        XCTAssertTrue(AudioLevel.isSilent([Float](repeating: 0, count: 16000)))
        // Quiet room noise, about -60 dBFS.
        let noise = (0..<16000).map { _ in Float.random(in: -0.001...0.001) }
        XCTAssertTrue(AudioLevel.isSilent(noise))
        // A tone of -20 dBFS for a tenth of a second in a second of silence.
        var tone = [Float](repeating: 0, count: 16000)
        for i in 8000..<9600 { tone[i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 16000) }
        XCTAssertFalse(AudioLevel.isSilent(tone))
    }

    // MARK: Time

    func testOneTimeFormatWithHoursForLongVideos() {
        let short = ClockFormat(duration: 25)
        XCTAssertEqual(short.string(9.2), "0:09.20")
        XCTAssertEqual(short.string(62.5), "1:02.50")
        XCTAssertEqual(short.widest.count, "00:00.00".count)
        let long = ClockFormat(duration: 70 * 60)
        XCTAssertEqual(long.string(125.12), "0:02:05.12", "every time of a long video has the hours")
        XCTAssertEqual(long.string(3725.3), "1:02:05.30")
        XCTAssertEqual(long.string(3725.3).count, long.widest.count)
        XCTAssertEqual(parseTimecode(long.string(3725.3)) ?? 0, 3725.3, accuracy: 0.001, "the text reads back")
        // A cue past an hour in a file of unknown length still gets its hours.
        XCTAssertEqual(ClockFormat(duration: 0).string(3725.3), "1:02:05.30")
    }

    // MARK: Defaults

    func testSpeechLanguageFollowsTheInterfaceOrTheMac() {
        XCTAssertEqual(WhisperEngine.defaultLanguage(interface: "ru", preferredLanguages: ["en-US"]), "ru")
        XCTAssertEqual(WhisperEngine.defaultLanguage(interface: "en", preferredLanguages: ["en-US", "ru-RU"]), "en")
        XCTAssertEqual(WhisperEngine.defaultLanguage(interface: "en", preferredLanguages: ["de-DE"]), "de")
        XCTAssertEqual(WhisperEngine.defaultLanguage(interface: "en", preferredLanguages: ["sv-SE"]), "auto", "a language the list lacks: detection")
        XCTAssertEqual(WhisperEngine.defaultLanguage(interface: "en", preferredLanguages: []), "auto")
    }

    /// The standard presets use a font that comes with the app and has Cyrillic, so a clean Mac shows no warning.
    func testStandardPresetsUseTheBundledFont() throws {
        let fonts = Self.root.appendingPathComponent("Fonts")
        let families = FontLibrary.registerFonts(inDirectory: fonts)
        for preset in SubtitlePreset.builtIn {
            XCTAssertEqual(preset.fontFamily, SubtitlePreset.defaultFontFamily)
            XCTAssertTrue(families.contains(preset.fontFamily), "\(preset.fontFamily) ships in Fonts/")
            XCTAssertTrue(FontLibrary.isAvailable(family: preset.fontFamily))
            XCTAssertTrue(FontLibrary.supportsCyrillic(family: preset.fontFamily))
            XCTAssertTrue(FontLibrary.faces(of: preset.fontFamily).contains { $0.styleName == preset.fontFace },
                          "\(preset.fontFamily) has the face \(preset.fontFace)")
        }
    }

    // MARK: Standard presets

    func testRestoringStandardPresetsByIdentifier() {
        var presets = SubtitlePreset.builtIn
        presets[0].fontSize = 140
        presets[0].name = "Мой Reels"
        presets.remove(at: 2)
        let mine = SubtitlePreset(name: "Свой")
        presets.append(mine)
        let restored = SubtitlePreset.restoringBuiltIn(in: presets)
        XCTAssertEqual(restored[0], SubtitlePreset.builtIn[0], "changed and renamed, found by its identifier")
        XCTAssertTrue(restored.contains(mine), "the person's own preset stays")
        XCTAssertTrue(restored.contains(SubtitlePreset.builtIn[2]), "a deleted one comes back")
        XCTAssertEqual(restored.count, 5)
        XCTAssertEqual(SubtitlePreset.restoringBuiltIn(in: restored), restored, "nothing to do the second time")
    }

    func testStandardPresetsSavedByAnOlderVersionAreFoundByName() {
        // Older versions gave the standard presets a new identifier on every launch and called the last one «Плашка».
        var old = SubtitlePreset.builtIn[3]
        old.id = UUID()
        old.name = "Плашка"
        old.boxPadding = 40
        let restored = SubtitlePreset.restoringBuiltIn(in: [old])
        let found = restored.first { $0.id == old.id }
        XCTAssertEqual(found?.boxPadding, SubtitlePreset.builtIn[3].boxPadding, "its look comes back")
        XCTAssertEqual(found?.name, SubtitlePreset.builtIn[3].name)
        XCTAssertEqual(restored.count, 4, "no copy next to it")
    }

    // MARK: Cutting into subtitles

    func testCancelledCutReturnsNothing() {
        let words = (0..<2000).map { Word(text: "слово\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
        let style = LayoutStyle(preset: SubtitlePreset.builtIn[0], canvas: CGSize(width: 1080, height: 1920))
        XCTAssertTrue(CueBuilder.build(words: words, style: style, isCancelled: { true }).isEmpty)
        XCTAssertFalse(CueBuilder.build(words: words, style: style).isEmpty)
    }
}
