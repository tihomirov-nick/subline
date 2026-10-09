import XCTest
import AppKit
import SwiftUI
import Darwin
@testable import Subline
@testable import SublineCore

/// How much of the window draws again, and how long the main thread works, when one thing changes. The window is set
/// up like the real one (offscreen, see OffscreenWindow) with a video of 200 subtitles. A part that starts drawing on
/// changes that are not its own, or a frame of playback that takes as long as in 2.2.0, fails here.
@MainActor
final class RenderCountTests: XCTestCase {
    private static let cueCount = 200

    override func setUp() async throws {
        TestEnvironment.setUp()
        try XCTSkipUnless(TestEnvironment.hasFFmpeg, "no Vendor/ffmpeg (scripts/fetch_ffmpeg.sh)")
    }

    override func tearDown() async throws {
        RenderCount.isCounting = false
        RenderCount.counts = [:]
    }

    // MARK: The window

    /// A video of `cueCount` subtitles of 1.6 s every 2 s (a tiny picture: only its length matters), opened in a window.
    private func openWindow() async throws -> (AppModel, OffscreenWindow) {
        let video = TestEnvironment.folder.appendingPathComponent("renders.mp4")
        if !FileManager.default.fileExists(atPath: video.path) {
            _ = try await FFmpeg.run(["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                                      "-f", "lavfi", "-i", "color=c=0x203040:s=64x112:r=5:d=\(Self.cueCount * 2 + 4)",
                                      "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono", "-t", "\(Self.cueCount * 2 + 4)",
                                      "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "16k",
                                      "-metadata", "comment=renders", video.path])
        }
        let model = AppModel()
        model.openMedia(video)
        try await TestEnvironment.wait("the video to open", timeout: 30) { model.media != nil && model.activity == nil }
        model.useTranscriptForTesting(TestEnvironment.transcript)
        let words = ["раз", "два", "три", "четыре", "пять", "шесть", "семь"]
        model.cues = (0..<Self.cueCount).map { index in
            Cue(start: 1 + Double(index) * 2, end: 2.6 + Double(index) * 2,
                text: (0..<(2 + index % 4)).map { words[($0 + index) % words.count] }.joined(separator: " "))
        }
        try await TestEnvironment.wait("the player", timeout: 20) { model.player.isReady }
        model.showInspector = true
        let window = OffscreenWindow.make(size: CGSize(width: 1400, height: 860))
        window.contentView = NSHostingView(rootView: MainView().environmentObject(model).environmentObject(model.modelStore)
            .environmentObject(model.fontStore).environmentObject(model.updater))
        model.player.seek(to: 101.2)
        settle(1.5)
        return (model, window)
    }

    private func settle(_ seconds: Double = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Runs `steps` steps of `action`, one frame each, and returns what drew (by name) and the main thread's CPU time
    /// per step in milliseconds.
    private func measure(steps: Int, _ action: (Int) -> Void) -> (counts: [String: Int], cpu: [Double]) {
        RenderCount.counts = [:]
        RenderCount.isCounting = true
        var cpu: [Double] = []
        for index in 0..<steps {
            let start = Self.mainThreadCPU()
            action(index)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
            cpu.append((Self.mainThreadCPU() - start) * 1000)
        }
        RenderCount.isCounting = false
        return (RenderCount.counts, cpu)
    }

    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(1, values.count))
    }

    /// The parts that must stay still: the top bar, the inspector, the transport bar itself.
    private let stillParts = ["TopBarContent", "PresetBar", "ScopeBar", "TabBar", "InspectorTabs", "TransportControls"]

    // MARK: Tests

    func testIdleDrawsNothing() async throws {
        let (_, window) = try await openWindow()
        defer { window.dispose() }
        let idle = measure(steps: 60) { _ in }
        XCTAssertEqual(idle.counts, [:], "nothing draws while nothing changes")
    }

    func testPlaybackRedrawsOnlyTheClockAndThePlayhead() async throws {
        let (model, window) = try await openWindow()
        defer { window.dispose() }
        model.player.setPlayingForTesting(true)
        settle()

        // Within one subtitle: only the time and the playhead move.
        let ticks = measure(steps: 60) { index in model.player.tickForTesting(101.3 + Double(index) / 100) }
        let moving: Set<String> = ["ClockText", "RemainingText", "ScrubberProgress"]
        XCTAssertTrue(Set(ticks.counts.keys).subtracting(moving).subtracting(["CueMarks"]).isEmpty,
                      "a frame of playback redraws the clock and the playhead, nothing else: \(ticks.counts)")
        XCTAssertLessThanOrEqual(ticks.counts["ScrubberProgress"] ?? 0, 60)
        XCTAssertLessThanOrEqual(ticks.counts["CueMarks"] ?? 0, 1, "the marks of the subtitles are drawn once, not per frame")
        print(String(format: "RenderCountTests: a frame of playback %.2f ms of the main thread", mean(ticks.cpu)))
        XCTAssertLessThan(mean(ticks.cpu), 4, "a frame of playback stays within 4 ms of the main thread (2.2.0: about 60 ms)")

        // Out of a subtitle and into the next one: their rows, the picture, the note about long subtitles (and the scope
        // switcher, whose «Субтитр» follows the subtitle under the playhead while nothing is selected).
        let next = measure(steps: 2) { index in model.player.tickForTesting(index == 0 ? 102.8 : 103.1) }
        XCTAssertLessThanOrEqual(next.counts["CueRow"] ?? 0, 2, "the subtitle under the playhead moving on redraws its rows only")
        for part in stillParts where part != "ScopeBar" {
            XCTAssertNil(next.counts[part], "\(part) stays still when the playhead moves to the next subtitle")
        }
        model.player.setPlayingForTesting(false)
    }

    func testTypingRedrawsTheRowNotTheInspector() async throws {
        let (model, window) = try await openWindow()
        defer { window.dispose() }
        let cue = try XCTUnwrap(model.cues.first { $0.start > 101 })
        model.beginTextEditing(cue)
        settle()
        let typing = measure(steps: 10) { index in
            model.editCueText(cue.id, cue.text + String(repeating: "а", count: index + 1))
        }
        XCTAssertLessThanOrEqual(typing.counts["CueRow"] ?? 0, 10, "a letter redraws the row typed in, once")
        for part in stillParts {
            XCTAssertNil(typing.counts[part], "\(part) stays still while a subtitle's text is typed")
        }
        model.endTextEditing(cue.id)
    }

    func testScrubbingKeepsTheListStill() async throws {
        let (model, window) = try await openWindow()
        defer { window.dispose() }
        model.player.seek(to: 150)
        settle(1)
        // While the playhead jumps quickly the list waits (only rows already on screen change their highlight); it shows
        // the subtitle once the playhead settles.
        let scrub = measure(steps: 30) { index in model.player.seek(to: 151 + Double(index) * 2.5) }
        XCTAssertLessThanOrEqual(scrub.counts["CueRow"] ?? 0, 30, "the list does not follow every step of scrubbing")
        for part in stillParts where part != "ScopeBar" {
            XCTAssertNil(scrub.counts[part], "\(part) stays still while scrubbing")
        }
        settle(1)
        let after = measure(steps: 30) { _ in }
        XCTAssertEqual(after.counts, [:], "once the list has caught up, nothing draws")
    }

    func testScrollingMakesOnlyTheRowsThatAppear() async throws {
        let (_, window) = try await openWindow()
        defer { window.dispose() }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let list = try XCTUnwrap(scrollViews(try XCTUnwrap(window.contentView))
            .filter { $0.frame.minX < 320 }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }, "the list of subtitles")
        let clip = list.contentView
        let start = clip.bounds.origin.y
        let scroll = measure(steps: 60) { index in
            clip.scroll(to: NSPoint(x: 0, y: start + CGFloat(index + 1) * 50))
            list.reflectScrolledClipView(clip)
        }
        // 3000 pt of rows about 70 pt high: about 45 rows come into view.
        XCTAssertLessThanOrEqual(scroll.counts["CueRow"] ?? 0, 70, "only the rows that come into view are made")
        for part in stillParts + ["CanvasArea", "SubtitleCanvas", "StatusHUD"] {
            XCTAssertNil(scroll.counts[part], "\(part) stays still while the list scrolls")
        }
        print(String(format: "RenderCountTests: a step of scrolling %.2f ms of the main thread", mean(scroll.cpu)))
        XCTAssertLessThan(mean(scroll.cpu), 12, "a step of scrolling stays well under a frame (2.2.0: about 50 ms)")
    }
}
