import XCTest
import AppKit
import SwiftUI
@testable import Subline
@testable import SublineCore

/// The top bar lies in the titlebar. A click on «Открыть», «Экспорт» or the style switch must reach the button, not
/// fall through to moving the window. The clicks go through NSApp.sendEvent, the way the system delivers them.
@MainActor
final class TopBarClickTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.setUp()
        try XCTSkipUnless(TestEnvironment.hasFFmpeg, "no Vendor/ffmpeg (scripts/fetch_ffmpeg.sh)")
    }

    func testTopBarButtonsTakeClicks() async throws {
        let video = try await TestEnvironment.makeVideo(named: "topbar.mp4")
        let model = AppModel()
        model.openMedia(video)
        try await TestEnvironment.wait("the video to open") { model.media != nil && model.activity == nil }
        model.useTranscriptForTesting(TestEnvironment.transcript)
        var panels: [String] = []
        AppModel.panelHandlerForTesting = { panels.append($0 is NSOpenPanel ? "open" : "save") }
        defer { AppModel.panelHandlerForTesting = nil }
        let inspectorShown = model.showInspector
        defer { model.showInspector = inspectorShown }
        model.showInspector = true

        let window = OffscreenWindow.make(size: CGSize(width: 1400, height: 860))
        defer { window.dispose() }
        let hosting = NSHostingView(rootView: MainView().environmentObject(model).environmentObject(model.modelStore)
            .environmentObject(model.fontStore).environmentObject(model.updater))
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertNotNil(window.toolbar, "the window is set up like the real one")

        let buttons = OffscreenWindow.buttons(in: hosting)
        func center(_ label: String) throws -> CGPoint {
            let frame = try XCTUnwrap(buttons[label], "no «\(label)» button")
            XCTAssertLessThan(window.frame.height - frame.maxY, 40, "«\(label)» is in the titlebar")
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let open = try center(L("Открыть"))
        let export = try center(L("Экспорт"))
        let style = try center(spokenText(L("Скрыть стиль (⌥⌘I)")))
        window.warmUp()

        window.click(at: open)
        XCTAssertEqual(panels, ["open"], "a click on «Открыть» opens the file panel")
        window.click(at: export)
        XCTAssertEqual(panels, ["open", "save"], "a click on «Экспорт» opens the save panel")
        window.click(at: style)
        XCTAssertFalse(model.showInspector, "a click on the switch hides the style")
        window.click(at: style)
        XCTAssertTrue(model.showInspector, "a second click shows it again")
    }
}

/// A window set up like the main one (the views add the compact toolbar and the transparent titlebar). AppKit and
/// SwiftUI route clicks only in a window on the window list, so it is ordered in, but it is transparent, far outside
/// every screen, deaf to the real mouse and never brought forward: nothing appears on screen. Moving and zooming do
/// nothing.
final class OffscreenWindow: NSWindow {
    private var mayOrder = false
    private var clicks = 0

    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if mayOrder { super.order(place, relativeTo: otherWin) }
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {}
    override func orderFrontRegardless() {}
    override func performDrag(with event: NSEvent) {}
    override func zoom(_ sender: Any?) {}
    override func miniaturize(_ sender: Any?) {}

    static func make(size: CGSize) -> OffscreenWindow {
        let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        window.isExcludedFromWindowsMenu = true
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.mayOrder = true
        window.orderBack(nil)
        window.mayOrder = false
        return window
    }

    func dispose() {
        mayOrder = true
        orderOut(nil)
        contentView = nil
        close()
    }

    /// A press and a release at `point` (window coordinates), then the run loop gets a moment for the action.
    func click(at point: CGPoint) {
        clicks += 1
        let time = ProcessInfo.processInfo.systemUptime
        let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated().compactMap { index, type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time + Double(index) * 0.05,
                               windowNumber: windowNumber, context: nil, eventNumber: clicks, clickCount: 1,
                               pressure: index == 0 ? 1 : 0)
        }
        guard events.count == 2 else { return }
        // The release waits in the queue: a tracking loop started by the press takes it from there.
        NSApp.postEvent(events[1], atStart: false)
        NSApp.sendEvent(events[0])
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// The first click into a window that has just appeared loses its release here (it comes with the next click), so
    /// two clicks on the title go first.
    func warmUp() {
        for _ in 0..<2 { click(at: CGPoint(x: 300, y: frame.height - 20)) }
    }

    /// Frames of the buttons by their names for VoiceOver, in window coordinates.
    static func buttons(in hosting: NSView) -> [String: CGRect] {
        guard let window = hosting.window else { return [:] }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        _ = window.accessibilityChildren()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        var found: [String: CGRect] = [:]
        func value(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        func walk(_ element: Any, _ depth: Int) {
            guard depth < 80, let node = element as? NSObject else { return }
            if value(node, "accessibilityRole") as? String == "AXButton", let label = value(node, "accessibilityLabel") as? String,
               let screen = (value(node, "accessibilityFrame") as? NSValue)?.rectValue, found[label] == nil {
                found[label] = screen.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            }
            for child in value(node, "accessibilityChildren") as? [Any] ?? [] { walk(child, depth + 1) }
        }
        walk(hosting, 0)
        return found
    }
}
