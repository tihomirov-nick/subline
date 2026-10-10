import AppKit
import SublineCore

/// While speech is recognized or a video is exported, Subline shows its icon in the menu bar: the subtitles plate with
/// its two caption lines cut out, standing still. Nothing in it moves, the progress is in the tooltip. At the end a check
/// mark or an exclamation mark stays for 1.5 s and the icon goes. A click brings the window to the front; a right click
/// or a Control-click opens the menu: «Остановить» the work, then the part every app of the family shares. The switch is
/// in Settings.
@MainActor
final class MenuBarIcon: NSObject {
    static let enabledKey = "menuBarIconDuringWork"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    enum Outcome { case success, failure }

    private enum Work { case recognition, export }

    /// What the menu asks of the model, which owns the work: stop it, look for an update, quit the way ⌘Q does.
    var stopWork: (() -> Void)?
    var checkForUpdates: (() -> Void)?
    var quit: (() -> Void)?

    private var item: NSStatusItem?
    private var work: Work?
    private var progress: Double?
    /// The end of the work, shown for a moment.
    private var outcome: Outcome?
    private var hideTask: Task<Void, Never>?
    private var shownFace: WorkGlyph.Face?
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        // The switch in Settings writes UserDefaults.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    /// Follows the activity of the window: recognition and export show the icon, anything else hides it.
    func show(_ activity: Activity?) {
        switch activity?.kind {
        case .transcribing: work = .recognition
        case .exporting: work = .export
        default: work = nil
        }
        progress = activity?.progress
        if work != nil {
            outcome = nil
            hideTask?.cancel()
        }
        render()
    }

    /// The work is over: a check mark or an exclamation mark for 1.5 s, then the icon goes.
    func finish(_ outcome: Outcome) {
        guard item != nil else { return }
        self.outcome = outcome
        render()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.outcome = nil
            self.render()
        }
    }

    // MARK: - Drawing

    /// What the icon shows now; nil when it is not shown.
    var face: WorkGlyph.Face? {
        if let outcome { return outcome == .success ? .success : .failure }
        return work == nil ? nil : .working
    }

    private func render() {
        guard let face, Self.isEnabled else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shownFace = nil
            return
        }
        let button = statusItem().button
        // The picture stands still: it is set when the face changes, while the progress only changes the tooltip.
        if face != shownFace {
            shownFace = face
            button?.image = WorkGlyph.image(face)
        }
        let text = tooltip
        if button?.toolTip != text {
            button?.toolTip = text
            button?.setAccessibilityLabel(text)
        }
    }

    private var tooltip: String {
        if let outcome { return outcome == .success ? L("Готово") : L("Не получилось") }
        let percent = progress.map { "\(Int(($0 * 100).rounded()))" }
        switch work {
        case .recognition: return percent.map { L("Распознаю речь: %@ %%", $0) } ?? L("Распознаю речь")
        case .export: return percent.map { L("Экспорт: %@ %%", $0) } ?? L("Экспорт")
        case nil: return ""
        }
    }

    private func statusItem() -> NSStatusItem {
        if let item { return item }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
        return item
    }

    // MARK: - Clicks and the menu

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            MainWindow.show()
        }
    }

    private func showMenu() {
        guard let item else { return }
        // The menu belongs to the item only while it is open: a left click keeps bringing the window forward.
        item.menu = makeMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The menu of the icon, in the order of the family standard: what can be done to the work, then «Настройки…»,
    /// «Проверить обновления…», «О приложении» and «Завершить». While the check mark or the exclamation mark shows,
    /// nothing is left to stop.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if outcome == nil, let work {
            menu.addItem(menuItem(work == .recognition ? L("Остановить распознавание") : L("Остановить экспорт"),
                              #selector(stopClicked)))
            menu.addItem(.separator())
        }
        menu.addItem(menuItem(L("Настройки…"), #selector(settingsClicked), key: ","))
        menu.addItem(menuItem(L("Проверить обновления…"), #selector(updatesClicked)))
        menu.addItem(menuItem(L("О приложении «Subline»"), #selector(aboutClicked)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("Завершить Subline"), #selector(quitClicked), key: "q"))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func stopClicked() {
        stopWork?()
    }

    /// The Settings window of the app, brought to the front: the app may be behind the window of another one. It opens
    /// as the item of the app menu does (⌘,), which SwiftUI makes for the Settings scene; failing that, by the action
    /// the scene answers (`showSettingsWindow:` since macOS 14, `showPreferencesWindow:` before).
    @objc private func settingsClicked() {
        MainWindow.activateApp()
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            menu.performActionForItem(at: index)
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// The window comes forward first: that is where the check shows what it finds.
    @objc private func updatesClicked() {
        MainWindow.show()
        checkForUpdates?()
    }

    @objc private func aboutClicked() {
        MainWindow.activateApp()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Quitting while the work runs asks first: the question has to be seen, so the app comes forward before it.
    @objc private func quitClicked() {
        MainWindow.activateApp()
        quit?()
    }
}

/// The glyph, drawn in code as a template image: the subtitles badge the app icon is drawn from, as it is, a filled plate
/// with two caption lines of capsules cut out of it, a short and a long one over a long and a short one. The image is as
/// high as the menu bar lets an icon be, 22 pt, and 29 pt wide, with the 28 × 20 pt plate in the middle and half a point
/// beside it, as in every app of the family. The status item is `variableLength`, as wide as the image and the menu bar's
/// own margins. The capsules are 2 pt thick and sit on whole pixels at 1x and at 2x, so they stay crisp on any screen.
enum WorkGlyph {
    enum Face: Hashable {
        /// Recognition or export: the four capsules cut through.
        case working
        /// The check mark cut out instead of the capsules.
        case success
        /// The exclamation mark cut out instead of the capsules.
        case failure
    }

    /// The canvas, and the plate in it, as wide against its height as the badge and as round in the corners.
    static let size = NSSize(width: 29, height: 22)
    static let plate = NSRect(x: 0.5, y: 1, width: 28, height: 20)
    private static let cornerRadius: CGFloat = 3
    /// The check mark and the exclamation mark.
    private static let line: CGFloat = 3
    /// The dot of the exclamation mark.
    private static let dot: CGFloat = 4.2
    private static let thickness: CGFloat = 2

    /// The capsules in reading order, the centres of their round ends from the top left of the canvas, so that a capsule
    /// is a line from x0 to x1 with round caps. The icon's proportions (both lines 9 thicknesses wide, a short capsule
    /// 7/3 of one, the gap one) rounded to whole pixels at 1x: lines 18 pt wide, a capsule 4 pt long, a gap of 2 pt, a
    /// long capsule up to the end, under it the same turned round, the lines 4 pt apart.
    static let marks: [(x0: CGFloat, x1: CGFloat, y: CGFloat)] = {
        let left = plate.minX + 5, width: CGFloat = 18, short: CGFloat = 4, gap: CGFloat = 2
        let top = plate.midY - 3, bottom = plate.midY + 3
        let end = thickness / 2, long = width - short - gap
        return [(left + end, left + short - end, top), (left + short + gap + end, left + width - end, top),
                (left + end, left + long - end, bottom), (left + long + gap + end, left + width - end, bottom)]
    }()

    /// One image per face: the menu bar keeps a drawn image, so a face that comes back costs nothing.
    @MainActor private static var images: [Face: NSImage] = [:]

    @MainActor static func image(_ face: Face) -> NSImage {
        if let image = images[face] { return image }
        let image = NSImage(size: size, flipped: true) { _ in
            draw(face)
            return true
        }
        image.isTemplate = true
        images[face] = image
        return image
    }

    private static func draw(_ face: Face) {
        NSColor.black.set()
        // The plate; everything drawn after it is cut out of it.
        NSBezierPath(roundedRect: plate, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let (x, y) = (plate.midX, plate.midY)
        switch face {
        case .working:
            for mark in marks { drawMark(mark) }
        case .success:
            stroke([NSPoint(x: x - 6, y: y + 0.5), NSPoint(x: x - 1.5, y: y + 5), NSPoint(x: x + 6, y: y - 4.5)], width: line)
        case .failure:
            stroke([NSPoint(x: x, y: y - 5.5), NSPoint(x: x, y: y)], width: line)
            NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y + 5 - dot / 2, width: dot, height: dot)).fill()
        }
    }

    private static func drawMark(_ mark: (x0: CGFloat, x1: CGFloat, y: CGFloat)) {
        stroke([NSPoint(x: mark.x0, y: mark.y), NSPoint(x: mark.x1, y: mark.y)], width: thickness)
    }

    private static func stroke(_ points: [NSPoint], width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
