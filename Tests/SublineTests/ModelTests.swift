import XCTest
import AppKit
@testable import Subline
@testable import SublineCore

/// The window's model with a real (generated) video: editing commands, export and its reasons, the saved work that
/// comes back at the next launch.
@MainActor
final class ModelTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.setUp()
        try XCTSkipUnless(TestEnvironment.hasFFmpeg, "no Vendor/ffmpeg (scripts/fetch_ffmpeg.sh)")
    }

    /// A model with the video open and subtitles cut from the test transcript by the one-line preset.
    private func openModel(video name: String) async throws -> (AppModel, URL) {
        let video = try await TestEnvironment.makeVideo(named: name)
        let model = AppModel()
        model.selectedPresetID = model.presets[1].id   // "Reels / Shorts — 1 строка"
        model.openMedia(video)
        try await TestEnvironment.wait("the video to open") { model.media != nil && model.activity == nil }
        model.useTranscriptForTesting(TestEnvironment.transcript)
        XCTAssertFalse(model.cues.isEmpty)
        return (model, video)
    }

    private func undoable(_ model: AppModel) -> UndoManager {
        let undo = UndoManager()
        model.undoManager = undo
        return undo
    }

    /// One action as the window does it: the undo group closes when the run loop turns.
    private func step(_ undo: UndoManager, _ action: () -> Void) {
        action()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: Export

    func testExportSaysWhyItCannotRun() async throws {
        let model = AppModel()
        XCTAssertEqual(model.exportBlocker(), L("Сначала откройте видео, затем распознайте речь"))
        model.export(.mp4H264)
        XCTAssertEqual(model.infoMessage?.title, L("Экспорт пока недоступен"))
        XCTAssertEqual(model.infoMessage?.text, model.exportBlocker())
        XCTAssertNil(model.errorMessage)

        let video = try await TestEnvironment.makeVideo(named: "reasons.mp4")
        model.openMedia(video)
        XCTAssertEqual(model.exportBlocker(), L("Видео ещё открывается"))
        try await TestEnvironment.wait("the video to open") { model.media != nil && model.activity == nil }
        XCTAssertEqual(model.exportBlocker(), L("Субтитров пока нет. Сначала распознайте речь"))
        model.useTranscriptForTesting(TestEnvironment.transcript)
        XCTAssertNil(model.exportBlocker(), "subtitles and a video: export can run")
        model.stageActivity(Activity(kind: .transcribing, title: "", progress: 0.5))
        XCTAssertEqual(model.exportBlocker(), L("Идёт распознавание речи. Экспорт будет доступен, когда оно закончится"))
        model.stageActivity(Activity(kind: .exporting, title: "", progress: 0.5))
        XCTAssertEqual(model.exportBlocker(), L("Экспорт уже идёт. Его ход виден над видео"))
        model.stageActivity(nil)
        XCTAssertNil(model.exportBlocker())
    }

    func testExportWritesTheVideoAndSRT() async throws {
        let (model, _) = try await openModel(video: "export.mp4")
        let output = TestEnvironment.folder.appendingPathComponent("export_out.mp4")
        try? FileManager.default.removeItem(at: output)
        model.exportForTesting(.mp4H264, to: output)
        XCTAssertEqual(model.activity?.kind, .exporting)
        try await TestEnvironment.wait("the export", timeout: 60) { model.activity == nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.exportNotice?.url, output)
        let info = try await FFmpeg.probe(output)
        XCTAssertTrue(info.hasVideo && info.hasAudio)

        // SRT is written in the background: the window stays free on long videos.
        let srt = TestEnvironment.folder.appendingPathComponent("export_out.srt")
        model.exportForTesting(.srt, to: srt)
        try await TestEnvironment.wait("the SRT") { model.exportNotice?.url == srt }
        XCTAssertEqual(model.lastExportURL, srt, "File → Show Last Export finds it")
        let text = try String(contentsOf: srt, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("1\n00:00:00,000 --> "), text)
        XCTAssertTrue(text.contains("наше"), text)
    }

    // MARK: Editing

    func testLastWordGoesToTheNextSubtitleAndBack() async throws {
        let (model, _) = try await openModel(video: "words.mp4")
        let undo = undoable(model)
        // One subtitle per phrase of the test transcript.
        model.cues = [Cue(start: 0, end: 1.2, text: "раз два наше"), Cue(start: 1.4, end: 2.15, text: "дело простое.")]
        let first = model.cues[0].id
        XCTAssertTrue(model.canMoveLastWordToNext(first))
        XCTAssertFalse(model.canMoveFirstWordToPrevious(first))
        step(undo) { model.moveLastWordToNext(first) }
        XCTAssertEqual(model.cues.map(\.text), ["раз два", "наше дело простое."])
        XCTAssertEqual(model.cues[0].end, 0.7, accuracy: 0.001, "cut when «наше» is said")
        XCTAssertEqual(model.cues[1].start, 0.7, accuracy: 0.001)
        XCTAssertEqual(undo.undoActionName, L("Перенос слова"))
        step(undo) { model.moveFirstWordToPrevious(model.cues[1].id) }
        XCTAssertEqual(model.cues.map(\.text), ["раз два наше", "дело простое."])
        undo.undo()
        undo.undo()
        XCTAssertEqual(model.cues.map(\.text), ["раз два наше", "дело простое."])
        XCTAssertEqual(model.cues[0].end, 1.2, accuracy: 0.001)
    }

    func testTypedLineBreakInOneLineSubtitleIsASpaceAndTypingIsOneUndoStep() async throws {
        let (model, _) = try await openModel(video: "typing.mp4")
        let undo = undoable(model)
        let cue = model.cues[0]
        let original = cue.text
        model.editingCueID = cue.id
        step(undo) { model.editCueText(cue.id, original + "\nнаше") }
        XCTAssertEqual(model.cues[0].text, original + " наше")
        step(undo) { model.editCueText(cue.id, original + " наше дело") }
        model.endTextEditing(cue.id)
        XCTAssertNil(model.editingCueID)
        undo.undo()
        XCTAssertEqual(model.cues[0].text, original, "one step brings back the text from before typing")
    }

    func testSplitAtTheTextCaret() async throws {
        let (model, _) = try await openModel(video: "split.mp4")
        model.cues = [Cue(start: 0, end: 2.15, text: "раз два наше дело простое.")]
        let id = model.cues[0].id
        model.editingCueID = id
        model.textCaret = TextCaret(cueID: id, offset: ("раз два наше" as NSString).length, text: model.cues[0].text, time: Date())
        model.splitCurrentCue()
        XCTAssertEqual(model.cues.map(\.text), ["раз два наше", "дело простое."])
        XCTAssertEqual(model.cues[1].start, 1.4, accuracy: 0.001, "the second part starts when «дело» is said")
    }

    func testTooLongSubtitleIsMarkedAndSplitToFit() async throws {
        let (model, _) = try await openModel(video: "fit.mp4")
        var text = ""
        for word in "Сегодня покажу как быстро сделать красивые субтитры для любого видео".split(separator: " ") {
            text += (text.isEmpty ? "" : " ") + word
            if model.renderer.fit(Cue(start: 0, end: 3, text: text)).lines >= 2 { break }
        }
        model.cues = [Cue(start: 0, end: 3, text: text)]
        let fit = model.lineFit(for: model.cues[0])
        XCTAssertTrue(fit.overflows)
        XCTAssertEqual(OverflowNote.title(fit), L("Не помещается в одну строку"))
        model.splitToFit(model.cues[0].id)
        XCTAssertEqual(model.cues.count, 2)
        XCTAssertTrue(model.cues.allSatisfy { !model.lineFit(for: $0).overflows })
    }

    // MARK: Saved work

    func testWorkComesBackAtTheNextLaunch() async throws {
        let (first, video) = try await openModel(video: "session.mp4")
        let youtube = first.presets[2].id
        first.selectedPresetID = youtube
        first.useTranscriptForTesting(TestEnvironment.transcript)
        let id = first.cues[0].id
        first.editCueText(id, "Наше дело правое")
        first.flushPendingSaves()   // what quitting does
        // The next launch starts with another preset chosen.
        UserDefaults.standard.set(first.presets[0].id.uuidString, forKey: "selectedPreset")

        let second = AppModel()
        XCTAssertNotEqual(second.selectedPresetID, youtube)
        second.restoreLastSession()
        try await TestEnvironment.wait("the session to come back") { !second.cues.isEmpty && second.activity == nil }
        XCTAssertEqual(second.mediaURL?.standardizedFileURL, video.standardizedFileURL)
        XCTAssertEqual(second.cues.first?.text, "Наше дело правое")
        XCTAssertEqual(second.selectedPresetID, youtube, "the video comes back with its preset")
        XCTAssertEqual(second.restoreNotice, video.lastPathComponent)
        XCTAssertNil(second.errorMessage)

        // Closed on purpose: the next launch starts empty.
        second.closeMedia()
        let third = AppModel()
        third.restoreLastSession()
        XCTAssertNil(third.mediaURL)
    }

    func testEditsOfTheOpenVideoAreWrittenBeforeAnotherOpens() async throws {
        let (model, video) = try await openModel(video: "switch-a.mp4")
        model.editCueText(model.cues[0].id, "правка до переключения")
        let other = try await TestEnvironment.makeVideo(named: "switch-b.mp4")
        model.openMedia(other)   // within the delay of the autosave
        let saved = TranscriptCache.load(for: video)
        XCTAssertEqual(saved?.cues.first?.text, "правка до переключения")
        try await TestEnvironment.wait("the other video") { model.media != nil && model.activity == nil }
    }
}
