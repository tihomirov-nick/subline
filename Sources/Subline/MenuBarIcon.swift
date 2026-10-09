import AppKit
import SublineCore

/// While speech is recognized or a video is exported, Subline shows its icon in the menu bar: the caption lines type
/// themselves in during recognition and fill up with the progress of an export; at the end a check mark or an
/// exclamation mark stays for 1.5 s and the icon goes. A click brings the window to the front. The animation is light,
/// at most 10 frames a second, and while the display sleeps or Reduce Motion is on the picture stands still and changes
/// only with the progress. The switch is in Settings.
@MainActor
final class MenuBarIcon: NSObject {
    static let enabledKey = "menuBarIconDuringWork"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    enum Outcome { case success, failure }

    private enum Work { case recognition, export }

    private var item: NSStatusItem?
    private var work: Work?
    private var progress: Double?
    /// The end of the work, shown for a moment.
    private var outcome: Outcome?
    private var hideTask: Task<Void, Never>?
    private var timer: Timer?
    private var frame = 0
    private var displayAsleep = false
    private var shownFace: WorkGlyph.Face?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { _ in }
        // The switch in Settings writes UserDefaults.
        observe(NotificationCenter.default, UserDefaults.didChangeNotification) { _ in }
    }

    /// Follows the activity of the window: recognition and export show the icon, anything else hides it.
    func show(_ activity: Activity?) {
        let before = work
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
        if work == .recognition && before != .recognition { frame = 0 }
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

    /// Recognition types the marks in one after another: the two dashes of the top line grow, two dots appear, the last
    /// dash grows, a pause with the full lines, a short blank. 20 frames of 0.1 s.
    private static let typing: [Double] = [0.34, 0.67, 1, 1.34, 1.67, 2, 3, 3, 4, 4, 4.34, 4.67, 5, 5, 5, 5, 5, 5, 0, 0]

    private var animates: Bool {
        work == .recognition && outcome == nil && !displayAsleep && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func render() {
        let face: WorkGlyph.Face?
        if let outcome {
            face = outcome == .success ? .success : .failure
        } else if let work {
            switch work {
            case .recognition where animates:
                face = .typing(Self.typing[frame % Self.typing.count])
            case .recognition:
                // Still: as many marks as the progress has reached.
                face = .typing(((progress ?? 0) * Double(WorkGlyph.markCount)).rounded(.up))
            case .export:
                face = .filling(((progress ?? 0) * 40).rounded() / 40)
            }
        } else {
            face = nil
        }
        guard let face, Self.isEnabled else {
            stopTimer()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shownFace = nil
            return
        }
        if animates { startTimer() } else { stopTimer() }
        let button = statusItem().button
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
        item.button?.action = #selector(bringWindowForward)
        self.item = item
        return item
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame += 1
                self.render()
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func bringWindowForward() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let window = NSApp.windows.first { $0.identifier?.rawValue == "main" } ?? NSApp.windows.first { $0.canBecomeMain }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping (MenuBarIcon) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.render()
            }
        })
    }
}

/// The glyph, drawn in code as a template image: the outline of the app icon's squircle with the sign inside, "— — •"
/// over "• —", in lines. The glyph is 14 × 14 pt, drawn on a 16 pt square; the image is 16 pt high and 15 pt wide, as in
/// every app of the family, with the glyph in the middle. Lines of 1.5 pt (3 px on Retina, the rows and the outline on
/// whole pixels) with round ends and joins, only the dots filled.
enum WorkGlyph {
    enum Face: Hashable {
        /// So many marks typed; a fraction grows the next dash.
        case typing(Double)
        /// The marks faint, filled from the left in reading order.
        case filling(Double)
        case success
        case failure
    }

    static var markCount: Int { marks.count }

    private static let line: CGFloat = 1.5
    private static let dot: CGFloat = 2.1

    /// The marks in reading order, a dot has the same start and end; coordinates from the top left. The proportions
    /// are the icon's: a dash 216 and a gap 58 of the 632 units of the sign, and inside the outline the sign is as wide
    /// as in the icon (632 of the 824 units of the body). The rows sit on whole pixels.
    private static let marks: [(x0: CGFloat, x1: CGFloat, y: CGFloat)] = {
        let width: CGFloat = 9.6, gap: CGFloat = 0.9
        let dash = (width - dot - 2 * gap) / 2
        let top: CGFloat = 6.25, bottom: CGFloat = 9.75
        var x = 8 - width / 2
        var marks: [(x0: CGFloat, x1: CGFloat, y: CGFloat)] = []
        for _ in 0..<2 {
            marks.append((x + line / 2, x + dash - line / 2, top))
            x += dash + gap
        }
        marks.append((x + dot / 2, x + dot / 2, top))
        x = 8 - (dot + gap + dash) / 2
        marks.append((x + dot / 2, x + dot / 2, bottom))
        x += dot + gap
        marks.append((x + line / 2, x + dash - line / 2, bottom))
        return marks
    }()

    /// One image per face: the menu bar keeps a drawn image, so a face that comes back costs nothing.
    @MainActor private static var images: [Face: NSImage] = [:]

    /// The width of the image in the menu bar, the same in every app of the family: half a point beside the glyph.
    static let width: CGFloat = 15

    @MainActor static func image(_ face: Face) -> NSImage {
        if let image = images[face] { return image }
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.translateBy(x: (width - 16) / 2, y: 0)
            draw(face)
            return true
        }
        image.isTemplate = true
        images[face] = image
        return image
    }

    private static func draw(_ face: Face) {
        NSColor.black.set()
        let outline = squircle(NSRect(x: 1.75, y: 1.75, width: 12.5, height: 12.5))
        outline.lineWidth = line
        outline.stroke()
        switch face {
        case .typing(let typed):
            for (index, mark) in marks.enumerated() {
                let amount = min(1, max(0, typed - Double(index)))
                if amount > 0 { drawMark(mark, length: amount) }
            }
        case .filling(let progress):
            let lengths = marks.map { $0.x0 == $0.x1 ? dot : $0.x1 - $0.x0 + line }
            let total = lengths.reduce(0, +)
            var before: CGFloat = 0
            for (index, mark) in marks.enumerated() {
                NSColor.black.withAlphaComponent(0.3).set()
                drawMark(mark, length: 1)
                let filled = min(1, max(0, (CGFloat(progress) * total - before) / lengths[index]))
                if filled > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    let left = mark.x0 == mark.x1 ? mark.x0 - dot / 2 : mark.x0 - line / 2
                    NSRect(x: left, y: 0, width: lengths[index] * filled, height: 16).clip()
                    NSColor.black.set()
                    drawMark(mark, length: 1)
                    NSGraphicsContext.restoreGraphicsState()
                }
                before += lengths[index]
            }
        case .success:
            stroke([NSPoint(x: 5, y: 8.25), NSPoint(x: 7.25, y: 10.5), NSPoint(x: 11, y: 5.75)])
        case .failure:
            stroke([NSPoint(x: 8, y: 4.75), NSPoint(x: 8, y: 8.75)])
            NSBezierPath(ovalIn: NSRect(x: 8 - dot / 2, y: 11 - dot / 2, width: dot, height: dot)).fill()
        }
    }

    private static func drawMark(_ mark: (x0: CGFloat, x1: CGFloat, y: CGFloat), length: Double) {
        if mark.x0 == mark.x1 {
            NSBezierPath(ovalIn: NSRect(x: mark.x0 - dot / 2, y: mark.y - dot / 2, width: dot, height: dot)).fill()
        } else {
            stroke([NSPoint(x: mark.x0, y: mark.y), NSPoint(x: mark.x0 + (mark.x1 - mark.x0) * CGFloat(length), y: mark.y)])
        }
    }

    private static func stroke(_ points: [NSPoint]) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = line
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// The body of the app icon (scripts/make_icon.swift): a superellipse with exponent 5.
    private static func squircle(_ rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
        let path = NSBezierPath()
        let a = rect.width / 2, b = rect.height / 2
        for step in 0...360 {
            let t = CGFloat(step) / 360 * 2 * .pi
            let c = cos(t), s = sin(t)
            let point = NSPoint(x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent),
                                y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent))
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
