import SwiftUI
import SublineCore

/// Playback under the video: subtitle and frame stepping, play/pause, the scrubber with the subtitles marked on it.
/// The scrubber keeps at least 160 pt: in a narrow window the remaining time goes first, then the frame buttons, the
/// subtitle buttons and the time (all of them have keys and menu items too).
///
/// During playback only the clock and the playhead redraw (they watch `PlaybackClock`); the bar itself redraws when
/// the subtitles' times, the length of the video or its width change.
struct TransportBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerController

    static let scrubberMinWidth: CGFloat = 160

    var body: some View {
        let _ = RenderCount.hit("TransportBar")
        TransportControls(model: model, player: player,
                          inputs: .init(duration: max(player.duration, 0.001), frameRate: player.frameRate, clock: model.clockFormat,
                                        hasCues: !model.cues.isEmpty, marks: model.cues.map { CueMark(start: $0.start, end: $0.end) }))
            .equatable()
    }
}

/// Where a subtitle is on the scrubber.
struct CueMark: Equatable {
    let start: Double
    let end: Double
}

private struct TransportControls: View, Equatable {
    struct Inputs: Equatable {
        let duration: Double
        let frameRate: Double
        let clock: ClockFormat
        let hasCues: Bool
        let marks: [CueMark]
    }

    let model: AppModel
    let player: PlayerController
    let inputs: Inputs
    @State private var width: CGFloat = 0

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.player === rhs.player && lhs.inputs == rhs.inputs
    }

    var body: some View {
        let _ = RenderCount.hit("TransportControls")
        let fit = Fit(width: width, clock: inputs.clock)
        HStack(spacing: 2) {
            if fit.cueButtons {
                IconButton(symbol: "backward.end.fill", help: L("Предыдущий субтитр (↑)"), size: 28, filled: false) {
                    model.selectAdjacentCue(-1)
                }
                .disabled(!inputs.hasCues)
            }
            if fit.frameButtons {
                IconButton(symbol: "backward.frame.fill", help: L("Кадр назад (←), секунда назад (⇧←)"), size: 28, filled: false) {
                    player.step(frames: -1)
                }
            }
            PlayButton(player: player)
                .padding(.horizontal, 3)
            if fit.frameButtons {
                IconButton(symbol: "forward.frame.fill", help: L("Кадр вперёд (→), секунда вперёд (⇧→)"), size: 28, filled: false) {
                    player.step(frames: 1)
                }
            }
            if fit.cueButtons {
                IconButton(symbol: "forward.end.fill", help: L("Следующий субтитр (↓)"), size: 28, filled: false) {
                    model.selectAdjacentCue(1)
                }
                .disabled(!inputs.hasCues)
            }
            if fit.time {
                ClockText(clock: player.clock, format: inputs.clock, frameRate: inputs.frameRate)
                    .padding(.leading, 6)
            }
            Scrubber(player: player, marks: inputs.marks, duration: inputs.duration, clock: inputs.clock)
                .frame(minWidth: TransportBar.scrubberMinWidth)
                .padding(.horizontal, 10)
            if fit.remaining {
                RemainingText(clock: player.clock, format: inputs.clock, duration: inputs.duration)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Palette.card))
        .background(WidthReader(width: $width))
    }

    /// What fits next to a scrubber of at least 160 pt: the parts go in the order of `Fit.levels` as the bar narrows.
    /// The widths are those the parts draw with (their frames are fixed), so nothing is laid out twice to find out.
    struct Fit {
        var cueButtons = true
        var frameButtons = true
        var time = true
        var remaining = true

        static let levels: [Fit] = [
            Fit(),
            Fit(remaining: false),
            Fit(frameButtons: false, remaining: false),
            Fit(cueButtons: false, frameButtons: false, remaining: false),
            Fit(cueButtons: false, frameButtons: false, time: false, remaining: false),
        ]

        @MainActor init(width: CGFloat, clock: ClockFormat) {
            // Before the first layout the width is unknown: everything, as in a wide window.
            guard width > 0 else { return }
            self = Self.levels.first { $0.needed(clock) <= width } ?? Self.levels[Self.levels.count - 1]
        }

        private init(cueButtons: Bool = true, frameButtons: Bool = true, time: Bool = true, remaining: Bool = true) {
            self.cueButtons = cueButtons
            self.frameButtons = frameButtons
            self.time = time
            self.remaining = remaining
        }

        @MainActor func needed(_ clock: ClockFormat) -> CGFloat {
            var widths: [CGFloat] = [36 + 6, TransportBar.scrubberMinWidth + 20]
            if cueButtons { widths += [28, 28] }
            if frameButtons { widths += [28, 28] }
            if time { widths.append(clock.width(size: 12.5, weight: .semibold) + 6) }
            if remaining { widths.append(clock.width(size: 12.5, weight: .medium) + 8) }
            return 7 + 10 + widths.reduce(0, +) + 2 * CGFloat(widths.count - 1)
        }
    }
}

/// The width the bar gets, for choosing what fits (read once per layout change, not on every frame of playback).
private struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { width = $0 }
        }
    }
}

/// The current time, redrawn with the playhead. Drawn in a canvas of a fixed size: a text whose content changes 60 times
/// a second made SwiftUI lay the whole window out again on every frame of playback (most of a frame's work).
private struct ClockText: View {
    @ObservedObject var clock: PlaybackClock
    let format: ClockFormat
    let frameRate: Double

    var body: some View {
        let _ = RenderCount.hit("ClockText")
        let text = format.string(clock.time)
        let width = format.width(size: 12.5, weight: .semibold)
        Canvas { context, size in
            context.draw(Text(text).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundColor(.white),
                         at: CGPoint(x: size.width, y: size.height / 2), anchor: .trailing)
        }
        .frame(width: width, height: 16)
        .help(Text(verbatim: L("Кадр %@", "\(Int((clock.time * frameRate).rounded(.down)))")))
        .accessibilityHidden(true)
    }
}

/// The time left, redrawn with the playhead (a canvas too, see `ClockText`).
private struct RemainingText: View {
    @ObservedObject var clock: PlaybackClock
    let format: ClockFormat
    let duration: Double

    var body: some View {
        let _ = RenderCount.hit("RemainingText")
        let text = "−" + format.string(max(0, duration - clock.time))
        let width = format.width(size: 12.5, weight: .medium) + 8
        Canvas { context, size in
            context.draw(Text(text).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundColor(Palette.secondary),
                         at: CGPoint(x: 0, y: size.height / 2), anchor: .leading)
        }
        .frame(width: width, height: 16)
        .help(L("Осталось"))
        .accessibilityHidden(true)
    }
}

/// The white round play button; the symbol turns into pause.
private struct PlayButton: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        let _ = RenderCount.hit("PlayButton")
        Button {
            player.togglePlay()
        } label: {
            symbol
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Brand.mark))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.88, ring: Circle()))
        .disabled(!player.isReady)
        .opacity(player.isReady ? 1 : 0.4)
        .help(player.isPlaying ? L("Пауза (пробел)") : L("Воспроизвести (пробел)"))
        .accessibilityLabel(player.isPlaying ? L("Пауза") : L("Воспроизвести"))
    }

    @ViewBuilder
    private var symbol: some View {
        let image = Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
        if #available(macOS 14.0, *) {
            image.contentTransition(.symbolEffect(.replace))
        } else {
            image
        }
    }

}

/// Timeline track: jumps on press, follows the pointer 1:1, shows the time under the pointer and where
/// subtitles are. The playhead is a white pill that grows while the pointer is over the track. With keyboard navigation
/// it takes the focus: ← and → move a second; VoiceOver sees it as a slider of the position.
struct Scrubber: View {
    let player: PlayerController
    let marks: [CueMark]
    let duration: Double
    var clock = ClockFormat(duration: 0)
    @State private var hoverX: CGFloat?
    @State private var isDragging = false
    @State private var resumeAfterDrag = false

    var body: some View {
        let _ = RenderCount.hit("Scrubber")
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let expanded = isDragging || hoverX != nil
            let trackHeight: CGFloat = expanded ? 8 : 5
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: trackHeight)
                ScrubberProgress(clock: player.clock, marks: marks, duration: duration, width: width, trackHeight: trackHeight,
                                 head: CGSize(width: expanded ? 6 : 4, height: expanded ? 22 : 16))
                if let x = hoverX, !isDragging {
                    Text(clock.string(Double(x / width) * duration))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                        .fixedSize()
                        .offset(x: min(max(0, x - 30), width - 60), y: -28)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: geometry.size.height)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: expanded)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            resumeAfterDrag = player.isPlaying
                            player.pause()
                        }
                        player.seek(to: Double(min(max(0, value.location.x / width), 1)) * duration)
                    }
                    .onEnded { _ in
                        isDragging = false
                        if resumeAfterDrag { player.play() }
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = min(max(0, location.x), width)
                case .ended: hoverX = nil
                }
            }
        }
        .frame(height: 30)
        .keyboardAdjustable(arrows: { step in player.seek(to: player.currentTime + Double(step)) })
        .accessibilityRepresentation {
                ScrubberSlider(clock: player.clock, player: player, duration: duration, format: clock)
        }
    }
}

/// What moves with the playhead: the played part of the track, the marks darker behind it and lighter ahead, the head.
/// The marks are drawn once, and everything here moves by offsets, which change no layout: a frame of playback only
/// moves layers.
private struct ScrubberProgress: View {
    @ObservedObject var clock: PlaybackClock
    let marks: [CueMark]
    let duration: Double
    let width: CGFloat
    let trackHeight: CGFloat
    let head: CGSize

    var body: some View {
        let _ = RenderCount.hit("ScrubberProgress")
        let playhead = width * CGFloat(min(1, max(0, clock.time / duration)))
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Brand.mark)
                    .frame(width: width, height: trackHeight)
                    .offset(x: max(trackHeight, playhead) - width)
                CueMarks(marks: marks, duration: duration, color: Color.white.opacity(0.34))
                    .equatable()
                    .frame(width: width, height: trackHeight)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width, height: trackHeight).offset(x: playhead)
                    }
                CueMarks(marks: marks, duration: duration, color: Color.black.opacity(0.28))
                    .equatable()
                    .frame(width: width, height: trackHeight)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width, height: trackHeight).offset(x: playhead - width)
                    }
            }
            .frame(width: width, height: trackHeight)
            .clipShape(Capsule())
            Capsule()
                .fill(Color.white)
                .frame(width: head.width, height: head.height)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .offset(x: min(max(0, playhead - head.width / 2), width - head.width))
        }
        .allowsHitTesting(false)
    }
}

/// VoiceOver's view of the scrubber: a slider of the position.
private struct ScrubberSlider: View {
    @ObservedObject var clock: PlaybackClock
    let player: PlayerController
    let duration: Double
    let format: ClockFormat

    var body: some View {
        Slider(value: Binding(get: { min(max(0, clock.time), duration) }, set: { player.seek(to: $0) }),
               in: 0...max(duration, 0.001)) {
            Text(L("Позиция"))
        }
        .accessibilityValue(L("%@ из %@", format.string(clock.time), format.string(duration)))
    }
}

/// Where the subtitles are, in one color (drawn again only when the subtitles' times change).
private struct CueMarks: View, Equatable {
    let marks: [CueMark]
    let duration: Double
    let color: Color

    var body: some View {
        let _ = RenderCount.hit("CueMarks")
        Canvas { context, size in
            guard duration > 0 else { return }
            for mark in marks {
                let x = CGFloat(mark.start / duration) * size.width
                let w = max(1.5, CGFloat((mark.end - mark.start) / duration) * size.width - 1)
                context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}
