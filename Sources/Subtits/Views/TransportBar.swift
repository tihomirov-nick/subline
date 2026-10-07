import SwiftUI
import SubtitsCore

/// Playback controls under the video: subtitle and frame stepping, play/pause, scrubber with subtitle marks.
/// A Liquid Glass capsule floating on the dark viewer.
struct TransportBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerController

    var body: some View {
        let duration = max(player.duration, 0.001)
        HStack(spacing: 2) {
            Button {
                model.selectAdjacentCue(-1)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(TransportButtonStyle())
            .help(L("Предыдущий субтитр (↑)"))
            .disabled(model.cues.isEmpty)

            Button {
                player.step(frames: -1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(TransportButtonStyle())
            .help(L("Кадр назад (←), секунда назад (⇧←)"))

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffectIfAvailable)
            }
            .buttonStyle(TransportButtonStyle(prominent: true))
            .padding(.horizontal, 2)
            .help(player.isPlaying ? L("Пауза (пробел)") : L("Воспроизвести (пробел)"))
            .disabled(!player.isReady)

            Button {
                player.step(frames: 1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(TransportButtonStyle())
            .help(L("Кадр вперёд (→), секунда вперёд (⇧→)"))

            Button {
                model.selectAdjacentCue(1)
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(TransportButtonStyle())
            .help(L("Следующий субтитр (↓)"))
            .disabled(model.cues.isEmpty)

            Text(TransportBar.format(player.currentTime))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .frame(width: 66, alignment: .trailing)
                .padding(.leading, 8)
                .help(Text(verbatim: L("Кадр %@", "\(player.currentFrame)")))

            Scrubber(player: player, cues: model.cues, duration: duration)
                .padding(.horizontal, 10)

            Text("−" + TransportBar.format(max(0, duration - player.currentTime)))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
                .help(L("Осталось"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 56)
        .glassSurface(Capsule())
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

/// Round transport button with hover and instant press feedback; the prominent one is the white
/// play button.
struct TransportButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        TransportButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct TransportButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let size: CGFloat = prominent ? 40 : 32
            configuration.label
                .font(.system(size: prominent ? 16 : 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.primary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(prominent ? Color.white.opacity(isEnabled ? (hovering ? 1 : 0.94) : 0.35)
                                            : Color.white.opacity(configuration.isPressed ? 0.2 : (hovering ? 0.11 : 0)))
                )
                .shadow(color: .black.opacity(prominent ? 0.25 : 0), radius: 6, y: 2)
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Circle())
                .onHover { hovering = $0 }
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
                    .fill(Color.white.opacity(0.16))
                    .frame(height: trackHeight)
                CueMarks(cues: cues, duration: duration)
                    .frame(height: trackHeight)
                    .clipShape(Capsule())
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(trackHeight, width * progress), height: trackHeight)
                Capsule()
                    .fill(Color.white)
                    .frame(width: head.width, height: head.height)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .offset(x: min(max(0, width * progress - head.width / 2), width - head.width))
                if let x = hoverX, !isDragging {
                    Text(TransportBar.format(Double(x / width) * duration))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassSurface(Capsule())
                        .fixedSize()
                        .offset(x: min(max(0, x - 30), width - 60), y: -30)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: geometry.size.height)
            .animation(.spring(response: 0.22, dampingFraction: 1), value: expanded)
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

private struct CueMarks: View {
    let cues: [Cue]
    let duration: Double

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            for cue in cues {
                let x = CGFloat(cue.start / duration) * size.width
                let w = max(1.5, CGFloat((cue.end - cue.start) / duration) * size.width - 1)
                context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Color.accentColor.opacity(0.8)))
            }
        }
        .allowsHitTesting(false)
    }
}

private extension ContentTransition {
    /// Symbol replace animation where available (macOS 14+), plain swap otherwise.
    static var symbolEffectIfAvailable: ContentTransition {
        if #available(macOS 14.0, *) { return .symbolEffect(.replace) }
        return .identity
    }
}
