import SwiftUI
import SublineCore

/// Playback under the video: subtitle and frame stepping, play/pause, the scrubber with the subtitles marked on it.
struct TransportBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerController

    var body: some View {
        let duration = max(player.duration, 0.001)
        HStack(spacing: 2) {
            IconButton(symbol: "backward.end.fill", help: L("Предыдущий субтитр (↑)"), size: 28, filled: false) {
                model.selectAdjacentCue(-1)
            }
            .disabled(model.cues.isEmpty)
            IconButton(symbol: "backward.frame.fill", help: L("Кадр назад (←), секунда назад (⇧←)"), size: 28, filled: false) {
                player.step(frames: -1)
            }
            PlayButton(player: player)
                .padding(.horizontal, 3)
            IconButton(symbol: "forward.frame.fill", help: L("Кадр вперед (→), секунда вперед (⇧→)"), size: 28, filled: false) {
                player.step(frames: 1)
            }
            IconButton(symbol: "forward.end.fill", help: L("Следующий субтитр (↓)"), size: 28, filled: false) {
                model.selectAdjacentCue(1)
            }
            .disabled(model.cues.isEmpty)

            Text(TransportBar.format(player.currentTime))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)
                .padding(.leading, 6)
                .help(Text(verbatim: L("Кадр %@", "\(player.currentFrame)")))

            Scrubber(player: player, cues: model.cues, duration: duration)
                .padding(.horizontal, 10)

            Text("−" + TransportBar.format(max(0, duration - player.currentTime)))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)
                .help(L("Осталось"))
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(Capsule().fill(Palette.card))
    }

    /// "0:12.48" or "1:02:03.40".
    static func format(_ seconds: Double) -> String {
        // Small epsilon: 9.2 s must read 9.20, not 9.19 (binary floating point).
        let total = Int((max(0, seconds) * 100 + 0.001).rounded(.down))
        let cs = total % 100
        let s = (total / 100) % 60
        let m = (total / 6000) % 60
        let h = total / 360000
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, cs) }
        return String(format: "%d:%02d.%02d", m, s, cs)
    }
}

/// The white round play button; the symbol turns into pause.
private struct PlayButton: View {
    @ObservedObject var player: PlayerController

    var body: some View {
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
        .buttonStyle(PressStyle(scale: 0.88))
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
/// subtitles are. The playhead is a white pill that grows while the pointer is over the track.
struct Scrubber: View {
    @ObservedObject var player: PlayerController
    let cues: [Cue]
    let duration: Double
    @State private var hoverX: CGFloat?
    @State private var isDragging = false
    @State private var resumeAfterDrag = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let progress = CGFloat(min(1, max(0, player.currentTime / duration)))
            let expanded = isDragging || hoverX != nil
            let trackHeight: CGFloat = expanded ? 8 : 5
            let head = CGSize(width: expanded ? 6 : 4, height: expanded ? 22 : 16)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Brand.mark)
                    .frame(width: max(trackHeight, width * progress), height: trackHeight)
                CueMarks(cues: cues, duration: duration, progress: progress)
                    .frame(height: trackHeight)
                    .clipShape(Capsule())
                Capsule()
                    .fill(Color.white)
                    .frame(width: head.width, height: head.height)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .offset(x: min(max(0, width * progress - head.width / 2), width - head.width))
                if let x = hoverX, !isDragging {
                    Text(TransportBar.format(Double(x / width) * duration))
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
    }
}

/// Where the subtitles are: lighter marks ahead of the playhead, darker ones on the played part.
private struct CueMarks: View {
    let cues: [Cue]
    let duration: Double
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            let playhead = size.width * progress
            let played = CGRect(x: 0, y: 0, width: playhead, height: size.height)
            let ahead = CGRect(x: playhead, y: 0, width: max(0, size.width - playhead), height: size.height)
            for cue in cues {
                let x = CGFloat(cue.start / duration) * size.width
                let w = max(1.5, CGFloat((cue.end - cue.start) / duration) * size.width - 1)
                let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                let before = rect.intersection(played)
                if !before.isNull, before.width > 0 { context.fill(Path(before), with: .color(.black.opacity(0.28))) }
                let after = rect.intersection(ahead)
                if !after.isNull, after.width > 0 { context.fill(Path(after), with: .color(.white.opacity(0.34))) }
            }
        }
        .allowsHitTesting(false)
    }
}
