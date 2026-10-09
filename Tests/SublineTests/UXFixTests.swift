import XCTest
import AppKit
import SwiftUI
@testable import Subline
@testable import SublineCore

/// The window after the UX fixes: the work found after the file moved, Open Recent and ⌘S, errors told for people,
/// questions before losing work, keys of the list, a long transcript cut in the background, VoiceOver names, and
/// pictures of the new states (drawn offscreen, nothing appears on screen).
@MainActor
final class UXFixTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.setUp()
        try XCTSkipUnless(TestEnvironment.hasFFmpeg, "no Vendor/ffmpeg (scripts/fetch_ffmpeg.sh)")
    }

    private func openModel(video name: String) async throws -> (AppModel, URL) {
        let video = try await TestEnvironment.makeVideo(named: name)
        let model = AppModel()
        model.selectedPresetID = model.presets[1].id
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

    private func step(_ action: () -> Void) {
        action()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func folder(_ name: String) throws -> URL {
        let url = TestEnvironment.folder.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Saved work (finding 6)

    func testWorkComesBackAfterTheFileWasMovedRenamedOrCopied() async throws {
        let (first, video) = try await openModel(video: "move-me.mp4")
        first.editCueText(first.cues[0].id, "правка до переноса")
        first.flushPendingSaves()

        let moved = try folder("moved").appendingPathComponent("другое имя.mp4")
        try FileManager.default.moveItem(at: video, to: moved)
        let second = AppModel()
        second.openMedia(moved)
        try await TestEnvironment.wait("the moved video") { !second.cues.isEmpty && second.activity == nil }
        XCTAssertEqual(second.cues.first?.text, "правка до переноса")

        let copy = try folder("copy").appendingPathComponent("копия.mp4")
        try FileManager.default.copyItem(at: moved, to: copy)
        let third = AppModel()
        third.openMedia(copy)
        try await TestEnvironment.wait("the copy") { !third.cues.isEmpty && third.activity == nil }
        XCTAssertEqual(third.cues.first?.text, "правка до переноса")
    }

    func testWorkSavedByAnOlderVersionStillComesBack() async throws {
        let video = try await TestEnvironment.makeVideo(named: "old-cache.mp4")
        let entry = TranscriptCache.Entry(transcript: TestEnvironment.transcript, cues: [Cue(start: 0, end: 1, text: "старая правка")],
                                          edited: true, layoutKey: "", modelID: "test", groups: nil, presetID: nil)
        let legacy = try XCTUnwrap(TranscriptCache.legacyKey(for: video))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        try data.write(to: AppPaths.cacheDir.appendingPathComponent("\(legacy).json"))
        XCTAssertEqual(TranscriptCache.load(for: video)?.cues.first?.text, "старая правка")
        // Saved again under the content key; the old copy goes.
        TranscriptCache.save(entry, for: video)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.cacheDir.appendingPathComponent("\(legacy).json").path))
        XCTAssertEqual(TranscriptCache.load(for: video)?.cues.first?.text, "старая правка")
    }

    func testOpenRecentRemembersFilesAndForgetsMissingOnes() async throws {
        let (model, video) = try await openModel(video: "recent.mp4")
        XCTAssertEqual(model.recentFiles.first?.path, video.standardizedFileURL.path)
        let gone = try await TestEnvironment.makeVideo(named: "recent-gone.mp4")
        model.openMedia(gone)
        try await TestEnvironment.wait("the second video") { model.media != nil && model.activity == nil }
        XCTAssertEqual(model.recentFiles.first?.lastPathComponent, "recent-gone.mp4")
        XCTAssertEqual(AppModel().recentFiles.first?.lastPathComponent, "recent-gone.mp4", "kept between launches")
        try FileManager.default.removeItem(at: gone)
        model.openRecent(model.recentFiles[0])
        XCTAssertEqual(model.infoMessage?.title, L("Файл не найден"))
        XCTAssertFalse(model.recentFiles.contains { $0.lastPathComponent == "recent-gone.mp4" })
        model.clearRecent()
        XCTAssertTrue(model.recentFiles.isEmpty)
    }

    func testSaveNowWritesTheWorkAtOnce() async throws {
        let (model, video) = try await openModel(video: "save-now.mp4")
        model.editCueText(model.cues[0].id, "сохранить сейчас")
        model.saveNow()
        XCTAssertEqual(TranscriptCache.load(for: video)?.cues.first?.text, "сохранить сейчас")
        XCTAssertEqual(model.savedFlash, 1)
    }

    // MARK: Errors (findings 7, 27)

    func testATextFileTellsWhatHappenedAndKeepsTheLogForDetails() async throws {
        let notes = try folder("text").appendingPathComponent("заметки.mp4")
        try "это не видео".write(to: notes, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.openMedia(notes)
        try await TestEnvironment.wait("the failure") { model.problem != nil }
        XCTAssertEqual(model.problem?.title, L("Файл не открылся"))
        XCTAssertTrue(model.problem?.message.contains("заметки.mp4") == true)
        XCTAssertFalse(model.problem?.message.contains("Invalid data") == true, "no raw ffmpeg text in the message")
        XCTAssertNotNil(model.problem?.details)
    }

    func testAPictureIsNotOpenedAsAVideo() async throws {
        let photo = try folder("photo").appendingPathComponent("photo.jpg")
        _ = try await FFmpeg.run(["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi",
                                  "-i", "color=c=red:s=320x240:d=1", "-frames:v", "1", photo.path])
        let model = AppModel()
        model.openMedia(photo)
        try await TestEnvironment.wait("the refusal") { model.problem != nil }
        XCTAssertEqual(model.problem?.title, L("Картинки Subline не открывает"))
        XCTAssertNil(model.mediaURL)
    }

    func testExportIntoAFolderWithoutWriteAccessSaysSo() async throws {
        let (model, _) = try await openModel(video: "locked.mp4")
        let locked = try folder("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        model.exportForTesting(.mp4H264, to: locked.appendingPathComponent("out.mp4"))
        try await TestEnvironment.wait("the export to fail", timeout: 60) { model.activity == nil && model.problem != nil }
        XCTAssertEqual(model.problem?.title, L("Нет доступа к папке"))
        XCTAssertTrue(model.problem?.message.contains(locked.lastPathComponent) == true)
        XCTAssertNotNil(model.problem?.details, "ffmpeg's lines under Details")

        model.problem = nil
        model.exportForTesting(.srt, to: locked.appendingPathComponent("out.srt"))
        try await TestEnvironment.wait("the SRT to fail") { model.problem != nil }
        XCTAssertEqual(model.problem?.title, L("Нет доступа к папке"))
    }

    func testNothingRecognizedTellsSilenceFromAnotherLanguage() {
        XCTAssertEqual(AppModel.nothingRecognized(silent: true, language: "ru").title, L("Речи не слышно"))
        let language = AppModel.nothingRecognized(silent: false, language: "ru")
        XCTAssertEqual(language.title, L("Речь не распознана"))
        XCTAssertTrue(language.message.contains(L("Русский")), "names the language that was tried")
        XCTAssertFalse(AppModel.nothingRecognized(silent: false, language: "auto").message.contains("«"))
    }

    // MARK: Questions before losing work (findings 8, 19, 20)

    func testRecognizingAgainOverEditsAsksFirst() async throws {
        let (model, _) = try await openModel(video: "again.mp4")
        model.editCueText(model.cues[0].id, "ручная правка")
        model.requestTranscription()
        XCTAssertEqual(model.confirmation?.title, L("Распознать речь заново?"))
        XCTAssertNil(model.activity, "nothing starts before the answer")
    }

    func testOpeningAnotherFileDuringRecognitionAsksFirst() async throws {
        let (model, video) = try await openModel(video: "busy.mp4")
        let other = try await TestEnvironment.makeVideo(named: "busy-other.mp4")
        model.stageActivity(Activity(kind: .transcribing, title: "", progress: 0.3))
        model.requestOpen(other)
        XCTAssertEqual(model.confirmation?.title, L("Остановить распознавание?"))
        XCTAssertEqual(model.mediaURL, video, "the open video stays until the answer")
        model.confirmation?.action()
        try await TestEnvironment.wait("the other video") { model.media != nil && model.activity == nil }
        XCTAssertEqual(model.mediaURL, other)
    }

    func testRestoringStandardPresetsAsksAndIsOneUndoStep() throws {
        let model = AppModel()
        let undo = undoable(model)
        model.requestRestoreBuiltInPresets()
        XCTAssertEqual(model.confirmation?.title, L("Восстановить стандартные пресеты?"))
        model.confirmation = nil

        let id = SubtitlePreset.builtInIDs[0]
        guard model.presets.contains(where: { $0.id == id }) else { throw XCTSkip("presets of an older version") }
        model.selectedPresetID = id
        step { model.preset.fontSize = 150 }
        step { model.restoreBuiltInPresets() }
        XCTAssertEqual(model.preset.fontSize, SubtitlePreset.builtIn[0].fontSize)
        undo.undo()
        XCTAssertEqual(model.preset.fontSize, 150, "undo brings the changed preset back")
        undo.redo()
        XCTAssertEqual(model.preset.fontSize, SubtitlePreset.builtIn[0].fontSize)
    }

    func testModelDeletionNamesTheSizeAndSlovo() {
        let message = ModelManagerView.deletionMessage(ModelDeletion(name: "Large v3 Turbo", size: "874,2 МБ", custom: false) {})
        XCTAssertTrue(message.contains("874,2 МБ"))
        XCTAssertTrue(message.contains("Slovo"))
    }

    // MARK: The list (findings 13, 22)

    func testDeleteRemovesTheSelectedSubtitlesInOneStep() async throws {
        let (model, _) = try await openModel(video: "delete.mp4")
        let undo = undoable(model)
        model.cues = [Cue(start: 0, end: 0.6, text: "раз два"), Cue(start: 0.7, end: 1.3, text: "наше дело"),
                      Cue(start: 1.4, end: 2.1, text: "простое.")]
        model.selectAllCues()
        XCTAssertEqual(model.selectedCueIDs.count, 3)
        XCTAssertEqual(model.scope, .cues)
        model.clearSelection()
        model.clickRow(model.cues[0], modifiers: .command)
        model.clickRow(model.cues[2], modifiers: .command)
        XCTAssertEqual(model.deletableCueIDs, [model.cues[0].id, model.cues[2].id])
        step { XCTAssertTrue(model.handle(.delete)) }
        XCTAssertEqual(model.cues.map(\.text), ["наше дело"])
        XCTAssertEqual(undo.undoActionName, L("Удаление субтитров"))
        undo.undo()
        XCTAssertEqual(model.cues.count, 3)
    }

    func testKeysOfThePlayerAndTheList() {
        XCTAssertEqual(KeyboardController.command(keyCode: 49, modifiers: []), .togglePlay)
        XCTAssertEqual(KeyboardController.command(keyCode: 124, modifiers: .shift), .jumpSeconds(1))
        XCTAssertEqual(KeyboardController.command(keyCode: 51, modifiers: []), .delete)
        XCTAssertEqual(KeyboardController.command(keyCode: 117, modifiers: []), .delete)
        XCTAssertEqual(KeyboardController.command(keyCode: 0, modifiers: .command), .selectAll)
        XCTAssertNil(KeyboardController.command(keyCode: 51, modifiers: .command), "⌘⌫ belongs to the text")
        XCTAssertNil(KeyboardController.command(keyCode: 49, modifiers: .command))
        // Keys the menus show as shortcuts never reach the menus from the keyboard.
        XCTAssertTrue(KeyboardController.Command.togglePlay.isMenuKey)
        XCTAssertTrue(KeyboardController.Command.delete.isMenuKey)
        XCTAssertFalse(KeyboardController.Command.selectAll.isMenuKey)
    }

    /// Space and ⌫ are shortcuts of menu items, yet typed into text they stay text: the key goes straight to the field.
    func testMenuKeysTypedIntoTextReachTheText() throws {
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        let window = NSWindow(contentRect: text.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = text
        window.makeFirstResponder(text)
        text.string = "раз"
        text.setSelectedRange(NSRange(location: 3, length: 0))
        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        var commands: [KeyboardController.Command] = []
        XCTAssertTrue(KeyboardController.consumes(try key(" ", 49)) { commands.append($0); return true })
        XCTAssertEqual(text.string, "раз ", "Space types a space")
        XCTAssertTrue(KeyboardController.consumes(try key("\u{7f}", 51)) { commands.append($0); return true })
        XCTAssertEqual(text.string, "раз", "⌫ deletes it")
        XCTAssertTrue(commands.isEmpty, "nothing reached the player or the list")
        window.contentView = nil
        window.close()
    }

    func testTabGoesOnToTheTextOfTheNextSubtitle() async throws {
        let (model, _) = try await openModel(video: "tab.mp4")
        model.cues = [Cue(start: 0, end: 0.6, text: "раз"), Cue(start: 0.7, end: 1.3, text: "два"), Cue(start: 1.4, end: 2.1, text: "три")]
        model.editText(after: model.cues[0].id, forward: true)
        XCTAssertEqual(model.textFocusRequest, model.cues[1].id)
        model.editText(after: model.cues[1].id, forward: false)
        XCTAssertEqual(model.textFocusRequest, model.cues[0].id)
        model.textFocusRequest = nil
        model.editText(after: model.cues[2].id, forward: true)
        XCTAssertNil(model.textFocusRequest, "past the last subtitle typing ends")
    }

    func testTabInTheTextAsksForTheNextSubtitle() {
        var tabs: [Bool] = []
        let editor = CueTextEditor(cueID: UUID(), text: "раз", allowsLineBreaks: false, onTab: { tabs.append($0) })
        let coordinator = editor.makeCoordinator()
        let view = CueTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(tabs, [true, false])
    }

    // MARK: Long transcripts (finding 18)

    private func longTranscript(words count: Int) -> Transcript {
        let sentence = "Сегодня покажу, как быстро сделать красивые субтитры для любого видео, а потом сохраним результат.".split(separator: " ")
        let words = (0..<count).map { i in
            Word(text: String(sentence[i % sentence.count]), start: Double(i) * 0.36, end: Double(i) * 0.36 + 0.3)
        }
        return Transcript(language: "ru", modelName: "test", duration: Double(count) * 0.36,
                          segments: [TranscriptSegment(start: 0, end: Double(count) * 0.36, text: "", words: words)])
    }

    func testALongTranscriptIsCutInTheBackground() async throws {
        let (model, _) = try await openModel(video: "long-cut.mp4")
        model.useTranscriptForTesting(longTranscript(words: 8000))
        XCTAssertTrue(model.isBuildingCues, "the window does not wait for the cut")
        try await TestEnvironment.wait("the cut") { !model.isBuildingCues }
        XCTAssertGreaterThan(model.cues.count, 500)

        // A cut that follows the style gives way to an edit made meanwhile.
        model.rebuildCues(onlyIfUnedited: true)
        XCTAssertTrue(model.isBuildingCues)
        model.editCueText(model.cues[0].id, "правка во время нарезки")
        try await TestEnvironment.wait("the second cut") { !model.isBuildingCues }
        XCTAssertEqual(model.cues[0].text, "правка во время нарезки")

        // A newer cut replaces an older one.
        model.rebuildCues()
        model.rebuildCues()
        try await TestEnvironment.wait("the newest cut") { !model.isBuildingCues }
        XCTAssertFalse(model.cuesEdited)
        XCTAssertGreaterThan(model.cues.count, 500)
    }

    // MARK: Sheets (finding 32)

    func testEscAndReturnCloseASheet() throws {
        var closed = 0
        let hosting = NSHostingView(rootView: SheetHeader(title: "Лист") { closed += 1 }.frame(width: 400, height: 60))
        hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func press(_ characters: String, _ code: UInt16) -> Bool {
            let event = try? XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            return event.map { hosting.performKeyEquivalent(with: $0) } ?? false
        }
        XCTAssertTrue(press("\u{1b}", 53), "Esc")
        XCTAssertTrue(press("\r", 36), "Return")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(closed, 2)
        window.contentView = nil
        window.close()
    }

    // MARK: VoiceOver (finding 15)

    private struct Node {
        let role: String
        let label: String
    }

    private func accessibilityNodes<V: View>(_ view: V, size: CGSize) -> [Node] {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        _ = window.accessibilityChildren()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        var nodes: [Node] = []
        func value(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        func walk(_ element: Any, _ depth: Int) {
            guard depth < 60, let object = element as? NSObject else { return }
            nodes.append(Node(role: value(object, "accessibilityRole") as? String ?? "",
                              label: value(object, "accessibilityLabel") as? String ?? ""))
            for child in value(object, "accessibilityChildren") as? [Any] ?? [] { walk(child, depth + 1) }
        }
        walk(hosting, 0)
        window.contentView = nil
        window.close()
        return nodes
    }

    func testVoiceOverFindsNamedSlidersSwitchesAndThePosition() async throws {
        let (model, _) = try await openModel(video: "voiceover.mp4")
        let inspector = accessibilityNodes(InspectorView().environmentObject(model), size: CGSize(width: 300, height: 1100))
        XCTAssertTrue(inspector.contains { $0.role == "AXSlider" && $0.label == L("Размер") }, "the size slider has a name")
        XCTAssertTrue(inspector.contains { $0.role == "AXSlider" && $0.label == L("Жирность") })
        XCTAssertTrue(inspector.contains { $0.label == L("Цвет текста") }, "the color swatch is named after its row")
        XCTAssertFalse(inspector.contains { $0.role == "AXSlider" && $0.label.isEmpty }, "no slider without a name")

        let transport = accessibilityNodes(TransportBar(player: model.player).environmentObject(model), size: CGSize(width: 800, height: 60))
        XCTAssertTrue(transport.contains { $0.role == "AXSlider" && $0.label == L("Позиция") }, "the scrubber is a slider of the position")

        let settings = accessibilityNodes(SettingsView().environmentObject(model.updater), size: CGSize(width: 380, height: 260))
        XCTAssertTrue(settings.contains { $0.role == "AXCheckBox" && $0.label == L("Звуковые эффекты") }, "a switch has its name")
    }

    // MARK: Pictures

    /// An hour-long video in the narrowest window with the narrowest list: every time has its hours and fits its field,
    /// the scrubber keeps 160 pt.
    func testTimesOfAnHourLongVideoInTheNarrowestWindow() async throws {
        let video = try folder("long").appendingPathComponent("long.mp4")
        _ = try await FFmpeg.run(["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                                  "-f", "lavfi", "-i", "color=c=0x203040:s=64x112:r=1:d=3730",
                                  "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono", "-t", "3730",
                                  "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-b:a", "16k", video.path])
        let model = AppModel()
        model.openMedia(video)
        try await TestEnvironment.wait("the long video", timeout: 30) { model.media != nil && model.activity == nil }
        XCTAssertTrue(model.clockFormat.showsHours)
        model.useTranscriptForTesting(TestEnvironment.transcript)
        model.cues = [Cue(start: 5.5, end: 7, text: "в начале"), Cue(start: 3725.3, end: 3727.4, text: "через час с лишним")]
        model.player.seek(to: 3725.5)
        let defaults = UserDefaults.standard
        defaults.set(260.0, forKey: "sidebarWidth")
        defer { defaults.removeObject(forKey: "sidebarWidth") }
        DebugHooks.stillFrame = true
        defer { DebugHooks.stillFrame = false }
        try TestEnvironment.render(MainView().environmentObject(model).environmentObject(model.modelStore)
                                    .environmentObject(model.fontStore).environmentObject(model.updater),
                                   size: CGSize(width: 1100, height: 680), name: "ux-hour-narrow.png")
    }

    func testPicturesOfTheNewStates() async throws {
        DebugHooks.stillFrame = true
        defer { DebugHooks.stillFrame = false }
        // The narrowest window with a long name and an hour-long time: the summary gives way, the scrubber keeps 160 pt.
        let (model, _) = try await openModel(video: "Очень длинное имя файла с интервью для проверки узкого окна.mp4")
        try TestEnvironment.render(MainView().environmentObject(model).environmentObject(model.modelStore)
                                    .environmentObject(model.fontStore).environmentObject(model.updater),
                                   size: CGSize(width: 1100, height: 680), name: "ux-narrow.png")
        try TestEnvironment.render(HelpView(), size: CGSize(width: 520, height: 560), name: "ux-help.png")
        try TestEnvironment.render(ProblemDetailsView(text: "[out#0/mp4 @ 0x12d605050] Error opening output /Users/a/Locked/.reels.part.mp4: Permission denied"),
                                   size: CGSize(width: 560, height: 320), name: "ux-details.png")

        // The inspector with its bigger targets (−/+, reset) on each tab.
        model.scope = .cues
        model.setStyle(\.fontSize, \.fontSize, 40)
        for tab in InspectorTab.allCases {
            model.inspectorTab = tab
            try TestEnvironment.render(InspectorView().environmentObject(model).block().padding(Metrics.gap).background(Palette.window)
                                        .foregroundStyle(.white).environment(\.colorScheme, .dark),
                                       size: CGSize(width: 316, height: 900), name: "ux-inspector-\(tab.rawValue).png")
        }
        model.clearSelection()

        // An audio file: the style does not reach the SRT, the inspector says so.
        let audio = try folder("audio").appendingPathComponent("voice.m4a")
        _ = try await FFmpeg.run(["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi",
                                  "-i", "sine=frequency=300:duration=2", "-c:a", "aac", audio.path])
        model.openMedia(audio)
        try await TestEnvironment.wait("the audio") { model.media != nil && model.activity == nil }
        try TestEnvironment.render(InspectorView().environmentObject(model).block().padding(Metrics.gap).background(Palette.window)
                                    .foregroundStyle(.white).environment(\.colorScheme, .dark),
                                   size: CGSize(width: 316, height: 420), name: "ux-audio-inspector.png")
    }
}
