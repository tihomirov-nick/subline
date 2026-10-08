import SwiftUI
import AppKit
import SublineCore

/// The middle block: the video with live subtitles, the transport under it and status pills above it.
struct CanvasArea: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                SubtitleCanvas(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Group {
                    if model.hasMedia {
                        TransportBar(player: player)
                            .frame(maxWidth: 820)
                    } else {
                        AspectBar()
                    }
                }
                .transition(.reveal(reduceMotion: reduceMotion))
            }
            .padding(Metrics.inset)
            StatusHUD(player: player)
                .padding(.top, Metrics.inset + 8)
                .padding(.horizontal, Metrics.inset)
        }
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: model.hasMedia)
    }
}

/// Frame proportions for designing presets before a video is opened.
private struct AspectBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(L("Формат превью"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            Segments(selection: $model.previewAspect,
                     items: PreviewAspect.allCases.map { SegmentItem($0, $0.title) },
                     large: true)
        }
        .frame(height: 30)
        .help(L("Пропорции кадра, пока видео не открыто"))
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
                        .transition(.reveal(reduceMotion: reduceMotion))
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07))
            )
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
        if model.hasVideo && player.isReady && !DebugHooks.stillFrame {
            PlayerLayerView(player: player.player)
        } else if let frame = model.frameImage {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                // The graphite of the app icon, lit from above.
                LinearGradient(colors: [Color(red: 0.2, green: 0.2, blue: 0.23), Color(red: 0.07, green: 0.07, blue: 0.08),
                                        Color(red: 0.02, green: 0.02, blue: 0.025)],
                               startPoint: .top, endPoint: .bottom)
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
                        .strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .offset(x: rect.minX * scale, y: rect.minY * scale)
                }
                ForEach(layout.words.filter { wordIndices.contains($0.index) }, id: \.index) { word in
                    let rect = word.rect.insetBy(dx: -4 / scale, dy: -3 / scale)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
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
            Haptics.tap()
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

/// Before a video is opened: what to do, in the middle of the frame.
private struct DropPrompt: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .padding(.bottom, 2)
            Text(L("Перетащите видео"))
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            Text(L("MP4, MOV, MKV, AVI, WEBM и другие"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            Button(L("Выбрать файл")) {
                model.showOpenPanel()
            }
            .appButton(.primary)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .padding(Metrics.inset)
    }
}

// MARK: - Status

/// Black pills above the video: progress of long operations, results, the playback copy.
struct StatusHUD: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var player: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            if let activity = model.activity {
                ActivityPill(activity: activity)
                    .transition(.reveal(reduceMotion: reduceMotion))
            } else if let notice = model.exportNotice {
                NoticePill(notice: notice)
                    .transition(.reveal(reduceMotion: reduceMotion))
            }
            if let progress = player.copyProgress {
                Pill {
                    ProgressView().controlSize(.small)
                    Text(L("Готовлю видео для просмотра · %@%%", "\(Int(progress * 100))"))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .transition(.reveal(reduceMotion: reduceMotion))
            } else if player.copyFailed {
                Pill {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.attention)
                    Text(L("Видео не проигрывается, но распознать и сохранить можно"))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .transition(.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: model.activity?.kind)
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: model.exportNotice)
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: player.copyProgress == nil)
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: player.copyFailed)
    }
}

/// A black capsule over the video, 40 pt high. A round icon or button at an end is concentric with the rounded end:
/// as far from the side as from the top and bottom. Text and spinners keep more room.
struct Pill<Content: View>: View {
    /// The space before the first item and after the last one.
    var leading: CGFloat = 14
    var trailing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(minHeight: 40)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }
}

private struct ActivityPill: View {
    @EnvironmentObject var model: AppModel
    let activity: Activity

    var body: some View {
        // The 26 pt icon is 7 pt from the edges of the capsule, the 24 pt × is 8 pt.
        Pill(leading: 7, trailing: activity.kind == .opening ? 14 : 8) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Brand.mark))
            VStack(alignment: .leading, spacing: 6) {
                Text(activity.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                ProgressLine(value: activity.progress)
                    .frame(width: 170)
            }
            if let progress = activity.progress {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            if activity.kind != .opening {
                IconButton(symbol: "xmark", help: L("Отменить"), size: 24) {
                    model.cancelActivity()
                }
            }
        }
        .padding(.vertical, 2)
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
        Pill(leading: 7, trailing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Brand.mark))
            Text(L("Сохранено"))
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Text(notice.url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(notice.url.path)
            Button(L("Открыть")) {
                NSWorkspace.shared.open(notice.url)
            }
            .appButton(.primary)
            .controlSize(.small)
            .fixedSize()
            IconButton(symbol: "folder", help: L("Показать в Finder"), size: 24) {
                NSWorkspace.shared.activateFileViewerSelecting([notice.url])
            }
            IconButton(symbol: "xmark", help: L("Скрыть"), size: 24) {
                model.exportNotice = nil
            }
        }
        .onAppear { Haptics.success() }
    }
}
