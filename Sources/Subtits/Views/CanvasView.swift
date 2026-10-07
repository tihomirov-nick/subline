import SwiftUI
import AppKit
import SubtitsCore

/// Center of the window: the video with live subtitles, the transport and floating status.
struct CanvasArea: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerController

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.067, green: 0.067, blue: 0.075)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                SubtitleCanvas(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.hasMedia {
                    TransportBar(player: player)
                        .frame(maxWidth: 820)
                } else {
                    AspectBar()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 16)
            StatusHUD(player: player)
                .padding(.top, 12)
        }
        // The viewer is a dark media surface in both appearances (like QuickTime), so its controls are dark too.
        .environment(\.colorScheme, .dark)
    }
}

/// Frame proportions for designing presets before a video is opened.
private struct AspectBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(L("Формат превью"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("", selection: $model.previewAspect) {
                ForEach(PreviewAspect.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 46)
        .glassSurface(Capsule())
    }
}

// MARK: - Canvas

struct SubtitleCanvas: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerController
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct DragContext {
        var anchor: CGPoint                 // anchor at drag start, video pixels
        var range: (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>)
        var centerOffset: CGPoint           // block center minus anchor, video pixels
    }

    private enum Press { case moveText, tap }

    @State private var press: Press?
    @State private var drag: DragContext?
    @State private var rubber: CGSize = .zero
    @State private var snapX = false
    @State private var snapY = false
    @State private var hoverRect: CGRect?
    @State private var cursorPushed = false

    var body: some View {
        GeometryReader { geometry in
            let canvas = model.canvasSize
            let fitted = Self.fit(canvas, in: geometry.size)
            let scale = canvas.width > 0 ? fitted.width / canvas.width : 1
            ZStack {
                picture
                if let overlay = model.overlayImage(pixelWidth: fitted.width * displayScale) {
                    Image(decorative: overlay, scale: displayScale)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(rubber)
                        .allowsHitTesting(false)
                }
                selectionOverlay(scale: scale)
                if drag != nil {
                    guides(size: fitted)
                } else if let rect = hoverRect {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: rect.width * scale + 12, height: rect.height * scale + 12)
                        .position(x: rect.midX * scale, y: rect.midY * scale)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if model.mediaURL == nil {
                    DropPrompt()
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: Look.frameRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Look.frameRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
            .contentShape(Rectangle())
            .gesture(pressGesture(scale: scale))
            .onContinuousHover { phase in
                updateHover(phase, scale: scale)
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if model.hasVideo && player.isReady {
            PlayerLayerView(player: player.player)
        } else if let frame = model.frameImage {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.17, green: 0.2, blue: 0.29), Color(red: 0.29, green: 0.23, blue: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if model.mediaURL != nil && model.hasVideo {
                    ProgressView().controlSize(.small)
                } else if model.media != nil {
                    Image(systemName: "waveform")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    private func guides(size: CGSize) -> some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            }
            .stroke(snapX ? Color.yellow : Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: snapX ? [] : [4, 4]))
            Path { path in
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            .stroke(snapY ? Color.yellow : Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: snapY ? [] : [4, 4]))
        }
        .allowsHitTesting(false)
    }

    // MARK: Dragging the subtitles

    /// Grabbing the subtitles moves them 1:1 (keeping the grab offset), they stick to the frame center
    /// with a haptic tick and resist past the frame edges, settling back with a spring on release.
    /// A click elsewhere on the video plays or pauses it.
    private func pressGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if press == nil {
                    press = startsOnText(value.startLocation, scale: scale) ? .moveText : .tap
                }
                if press == .moveText, hypot(value.translation.width, value.translation.height) >= 3 {
                    moveText(translation: value.translation, scale: scale)
                }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) >= 4
                if press == .tap, !moved, model.hasVideo {
                    player.togglePlay()
                }
                if press == .moveText {
                    if drag == nil, !moved {
                        // A click on the text selects the word under the pointer (⇧ adds words).
                        selectWord(at: value.startLocation, scale: scale)
                    } else {
                        endMove()
                    }
                }
                press = nil
            }
    }

    private func selectWord(at location: CGPoint, scale: CGFloat) {
        guard scale > 0, let cue = model.previewCue, !model.isSampleCue, let layout = model.previewLayout() else { return }
        let point = CGPoint(x: location.x / scale, y: location.y / scale)
        let index = layout.wordIndex(at: point, tolerance: 6 / scale)
            ?? layout.words.min(by: { distance($0.rect, point) < distance($1.rect, point) })?.index
        guard let index else { return }
        model.clickWord(index, in: cue, extend: NSEvent.modifierFlags.contains(.shift))
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    /// Selected words and the subtitle edited in the current scope.
    @ViewBuilder
    private func selectionOverlay(scale: CGFloat) -> some View {
        if let cue = model.previewCue, !model.isSampleCue, let layout = model.previewLayout() {
            let wordIndices = model.wordSelection?.cueID == cue.id && model.scope == .words ? model.wordSelection?.indices ?? [] : []
            let editsThisCue = model.scope == .cues && model.scopeCueIDs.contains(cue.id)
                || { if case .group(let id) = model.scope { return cue.groupID == id }; return false }()
            ZStack(alignment: .topLeading) {
                if editsThisCue && drag == nil {
                    let rect = layout.blockRect.insetBy(dx: -10 / scale, dy: -8 / scale)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .offset(x: rect.minX * scale, y: rect.minY * scale)
                }
                ForEach(layout.words.filter { wordIndices.contains($0.index) }, id: \.index) { word in
                    let rect = word.rect.insetBy(dx: -4 / scale, dy: -3 / scale)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .offset(x: rect.minX * scale, y: rect.minY * scale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(rubber)
            .allowsHitTesting(false)
        }
    }

    private func startsOnText(_ location: CGPoint, scale: CGFloat) -> Bool {
        guard scale > 0, let rect = model.previewBlockGeometry()?.rect else { return false }
        return rect.insetBy(dx: -14 / scale, dy: -14 / scale).contains(CGPoint(x: location.x / scale, y: location.y / scale))
    }

    private func moveText(translation: CGSize, scale: CGFloat) {
        let canvas = model.canvasSize
        if drag == nil {
            model.prepareForPositionDrag()
            guard let geometry = model.previewBlockGeometry() else { return }
            let style = model.effectiveStyle
            let anchor = CGPoint(x: style.positionX * canvas.width, y: style.positionY * canvas.height)
            drag = DragContext(anchor: anchor, range: geometry.range,
                               centerOffset: CGPoint(x: geometry.rect.midX - anchor.x, y: geometry.rect.midY - anchor.y))
            NSCursor.closedHand.set()
        }
        guard let context = drag, scale > 0 else { return }
        var x = context.anchor.x + translation.width / scale
        var y = context.anchor.y + translation.height / scale

        let threshold = 7 / scale
        let nowSnapX = abs(x + context.centerOffset.x - canvas.width / 2) < threshold
        let nowSnapY = abs(y + context.centerOffset.y - canvas.height / 2) < threshold
        if nowSnapX { x = canvas.width / 2 - context.centerOffset.x }
        if nowSnapY { y = canvas.height / 2 - context.centerOffset.y }
        if (nowSnapX && !snapX) || (nowSnapY && !snapY) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snapX = nowSnapX
        snapY = nowSnapY

        var overshoot = CGSize.zero
        if x < context.range.x.lowerBound {
            overshoot.width = rubberBand(x - context.range.x.lowerBound, dimension: canvas.width)
            x = context.range.x.lowerBound
        } else if x > context.range.x.upperBound {
            overshoot.width = rubberBand(x - context.range.x.upperBound, dimension: canvas.width)
            x = context.range.x.upperBound
        }
        if y < context.range.y.lowerBound {
            overshoot.height = rubberBand(y - context.range.y.lowerBound, dimension: canvas.height)
            y = context.range.y.lowerBound
        } else if y > context.range.y.upperBound {
            overshoot.height = rubberBand(y - context.range.y.upperBound, dimension: canvas.height)
            y = context.range.y.upperBound
        }

        model.setPosition(x: Double(x / canvas.width), y: Double(y / canvas.height))
        rubber = CGSize(width: overshoot.width * scale, height: overshoot.height * scale)
    }

    private func endMove() {
        drag = nil
        snapX = false
        snapY = false
        withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
            rubber = .zero
        }
        (hoverRect == nil ? NSCursor.arrow : NSCursor.openHand).set()
    }

    private func updateHover(_ phase: HoverPhase, scale: CGFloat) {
        guard drag == nil else { return }
        var inside: CGRect?
        if case .active(let location) = phase, scale > 0, let rect = model.previewBlockGeometry()?.rect {
            let point = CGPoint(x: location.x / scale, y: location.y / scale)
            if rect.insetBy(dx: -12, dy: -12).contains(point) { inside = rect }
        }
        if (inside != nil) != (hoverRect != nil) {
            withAnimation(Motion.quick) { hoverRect = inside }
            if inside != nil, !cursorPushed {
                NSCursor.openHand.push()
                cursorPushed = true
            } else if inside == nil, cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        } else if inside != nil {
            hoverRect = inside
        }
    }

    static func fit(_ size: CGSize, in container: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        return CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }
}

private struct DropPrompt: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .padding(.bottom, 4)
            Text(L("Перетащите видео"))
                .font(.system(size: 19, weight: .bold))
            Text(L("MP4, MOV, MKV, AVI, WEBM и другие форматы"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                model.showOpenPanel()
            } label: {
                Label(L("Выбрать файл…"), systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .glassProminentButton()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(24)
    }
}

// MARK: - Status

/// Floating status above the video: progress of long operations, results, playback copy.
struct StatusHUD: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            if let activity = model.activity {
                ActivityPill(activity: activity)
                    .transition(.materialize(reduceMotion: reduceMotion))
            } else if let notice = model.exportNotice {
                NoticePill(notice: notice)
                    .transition(.materialize(reduceMotion: reduceMotion))
            }
            if let progress = player.copyProgress {
                Pill {
                    ProgressView().controlSize(.small)
                    Text(L("Готовлю видео для просмотра · %@%%", "\(Int(progress * 100))"))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                }
                .transition(.materialize(reduceMotion: reduceMotion))
            } else if player.copyFailed {
                Pill {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L("Это видео не получается воспроизвести, но распознать и экспортировать его можно"))
                        .font(.system(size: 12, weight: .medium))
                }
                .transition(.materialize(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: model.activity?.kind)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: model.exportNotice)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: player.copyProgress == nil)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: player.copyFailed)
    }
}

/// Glass capsule for status messages.
struct Pill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(Capsule())
    }
}

private struct ActivityPill: View {
    @EnvironmentObject var model: AppModel
    let activity: Activity

    var body: some View {
        Pill {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.title)
                    .font(.system(size: 12.5, weight: .semibold))
                if let progress = activity.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                        .controlSize(.small)
                }
            }
            if let progress = activity.progress {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            if activity.kind != .opening {
                Button {
                    model.cancelActivity()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help(L("Отменить"))
            }
        }
    }

    private var icon: String {
        switch activity.kind {
        case .opening: return "film"
        case .transcribing: return "waveform"
        case .exporting: return "square.and.arrow.up"
        }
    }
}

private struct NoticePill: View {
    @EnvironmentObject var model: AppModel
    let notice: ExportNotice

    var body: some View {
        Pill {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.green.gradient))
            Text(L("Сохранено: %@", "\(notice.url.lastPathComponent)"))
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260)
            Button(L("Показать в Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([notice.url])
            }
            .glassButton()
            .controlSize(.small)
            Button(L("Открыть")) {
                NSWorkspace.shared.open(notice.url)
            }
            .glassProminentButton()
            .controlSize(.small)
            Button {
                model.exportNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(L("Скрыть"))
        }
    }
}
