import XCTest
import AppKit
import SwiftUI
@testable import Subline
@testable import SublineCore

/// Pictures of the views, drawn offscreen (nothing appears on screen): the subtitle being typed in, a subtitle that does
/// not fit its line, the Export button that says why it cannot run, the saved mark.
@MainActor
final class RenderTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.setUp()
        try XCTSkipUnless(TestEnvironment.hasFFmpeg, "no Vendor/ffmpeg (scripts/fetch_ffmpeg.sh)")
    }

    func testSubtitleListAndWindow() async throws {
        let video = try await TestEnvironment.makeVideo(named: "render.mp4")
        let model = AppModel()
        model.selectedPresetID = model.presets[1].id   // one line
        // The window before a video: the Export button looks unavailable and says why.
        let empty = try TestEnvironment.render(MainView().environmentObject(model).environmentObject(model.modelStore)
                                                .environmentObject(model.fontStore).environmentObject(model.updater),
                                               size: CGSize(width: 1300, height: 760), name: "window-empty.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))

        model.openMedia(video)
        try await TestEnvironment.wait("the video to open") { model.media != nil && model.activity == nil }
        model.useTranscriptForTesting(TestEnvironment.transcript)
        var cues = model.cues
        cues[0].text = "раз два наше дело простое и ещё очень длинный хвост из слов, который не влезет"
        model.cues = cues
        model.editingCueID = model.cues.count > 1 ? model.cues[1].id : nil
        XCTAssertTrue(model.lineFit(for: model.cues[0]).overflows)
        DebugHooks.stillFrame = true

        // The list as the window draws it: a black block on graphite, white text.
        try TestEnvironment.render(SidebarView().environmentObject(model).environmentObject(model.modelStore)
                                    .environmentObject(model.updater)
                                    .block().padding(Metrics.gap).background(Palette.window)
                                    .foregroundStyle(.white).environment(\.colorScheme, .dark),
                                   size: CGSize(width: 320, height: 760), name: "sidebar-editing.png")
        try TestEnvironment.render(MainView().environmentObject(model).environmentObject(model.modelStore)
                                    .environmentObject(model.fontStore).environmentObject(model.updater),
                                   size: CGSize(width: 1300, height: 760), name: "window-video.png")
        DebugHooks.stillFrame = false
    }
}
