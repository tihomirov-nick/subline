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

    /// Recognition types the capsules in one after another, each growing from its left end at one pace: the short and
    /// the long one of the top line, a beat at the line break, the long and the short one of the bottom line, a pause
    /// with the full lines, a short blank. 20 frames of 0.1 s.
    private static let typing: [Double] = [0.5, 1, 1.25, 1.5, 1.75, 2, 2, 2.25, 2.5, 2.75, 3, 3.5, 4, 4, 4, 4, 4, 4, 0, 0]

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
        MainWindow.show()
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

/// The glyph, drawn in code as a template image: the subtitles badge the app icon is drawn from, as it is, a filled plate
/// with two caption lines of capsules cut out of it, a short and a long one over a long and a short one. The image is
/// 16 pt high and 15 pt wide, as in every app of the family, with the 14 × 10 pt plate in the middle. The capsules are
/// 1 pt thick and sit on whole pixels at 1x and at 2x, so they stay crisp on any screen.
enum WorkGlyph {
    enum Face: Hashable {
        /// So many capsules typed; a fraction grows the next one.
        case typing(Double)
        /// The capsules cut out faintly, then through, from the left in reading order.
        case filling(Double)
        case success
        case failure
    }

    static var markCount: Int { marks.count }

    /// The check mark and the exclamation mark.
    private static let line: CGFloat = 1.5
    /// The dot of the exclamation mark.
    private static let dot: CGFloat = 2.1
    private static let thickness: CGFloat = 1

    /// The capsules in reading order, the centres of their round ends from the top left of the 16 pt square, so that a
    /// capsule is a line from x0 to x1 with round caps. The icon's proportions (both lines 9 thicknesses wide, a short
    /// capsule 7/3 of one, the gap one) rounded to whole pixels at 1x: lines 9 pt wide, a capsule 2 pt long, a gap of
    /// 1 pt, a long capsule up to the end, under it the same turned round, the lines 2 pt apart.
    private static let marks: [(x0: CGFloat, x1: CGFloat, y: CGFloat)] = {
        let left: CGFloat = 3.5, width: CGFloat = 9, short: CGFloat = 2, gap: CGFloat = 1
        let top: CGFloat = 6.5, bottom: CGFloat = 9.5
        let end = thickness / 2, long = width - short - gap
        return [(left + end, left + short - end, top), (left + short + gap + end, left + width - end, top),
                (left + end, left + long - end, bottom), (left + long + gap + end, left + width - end, bottom)]
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
        // The plate, as wide against its height as the badge and as round in the corners; everything drawn after it is
        // cut out of it.
        NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 14, height: 10), xRadius: 1.5, yRadius: 1.5).fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        switch face {
        case .typing(let typed):
            for (index, mark) in marks.enumerated() {
                let amount = min(1, max(0, typed - Double(index)))
                if amount > 0 { drawMark(mark, length: amount) }
            }
        case .filling(let progress):
            let lengths = marks.map { $0.x1 - $0.x0 + thickness }
            let total = lengths.reduce(0, +)
            var before: CGFloat = 0
            for (index, mark) in marks.enumerated() {
                NSColor.black.withAlphaComponent(0.3).set()
                drawMark(mark, length: 1)
                let filled = min(1, max(0, (CGFloat(progress) * total - before) / lengths[index]))
                if filled > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    NSRect(x: mark.x0 - thickness / 2, y: 0, width: lengths[index] * filled, height: 16).clip()
                    NSColor.black.set()
                    drawMark(mark, length: 1)
                    NSGraphicsContext.restoreGraphicsState()
                }
                before += lengths[index]
            }
        case .success:
            stroke([NSPoint(x: 5, y: 8.25), NSPoint(x: 7.25, y: 10.5), NSPoint(x: 11, y: 5.75)], width: line)
        case .failure:
            stroke([NSPoint(x: 8, y: 5.25), NSPoint(x: 8, y: 8)], width: line)
            NSBezierPath(ovalIn: NSRect(x: 8 - dot / 2, y: 10.5 - dot / 2, width: dot, height: dot)).fill()
        }
    }

    private static func drawMark(_ mark: (x0: CGFloat, x1: CGFloat, y: CGFloat), length: Double) {
        stroke([NSPoint(x: mark.x0, y: mark.y), NSPoint(x: mark.x0 + (mark.x1 - mark.x0) * CGFloat(length), y: mark.y)],
               width: thickness)
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
