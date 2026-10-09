import SwiftUI
import AppKit
import SublineCore

/// The left block: speech recognition on top, the subtitles below, an update of Subline at the bottom when there is one.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    @EnvironmentObject var updater: Updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if modelStore.hasAnyModel {
                    RecognitionPanel()
                } else {
                    DownloadModelPanel()
                }
            }
            .padding([.horizontal, .top], Metrics.inset)
            .padding(.bottom, Metrics.inset)
            .transition(.reveal(reduceMotion: reduceMotion))
            Separator(leading: 0)
                .padding(.horizontal, Metrics.inset)
            SubtitlesHeader()
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 10)
                .padding(.bottom, 8)
            if model.needsRebuild {
                RebuildBanner()
                    .padding(.horizontal, Metrics.inset)
                    .padding(.bottom, 8)
                    .transition(.reveal(reduceMotion: reduceMotion))
            }
            if !model.cues.isEmpty {
                GroupsBar()
                    .padding(.horizontal, Metrics.inset - 2)
                    .padding(.bottom, 6)
            }
            ZStack {
                if model.cues.isEmpty {
                    EmptyState()
                        .transition(.reveal(reduceMotion: reduceMotion))
                } else {
                    CueList(playheadCue: model.playheadCue, player: model.player)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            if updater.state != .idle {
                UpdateBanner()
                    .padding(.horizontal, Metrics.inset)
                    .padding(.top, 4)
                    .padding(.bottom, Metrics.inset)
                    .transition(.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: modelStore.hasAnyModel)
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: updater.state == .idle)
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: model.needsRebuild)
        .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: model.cues.isEmpty)
    }
}

// MARK: - Recognition

private struct RecognitionPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                MenuRow(title: L("Модель"), value: modelTitle) {
                    modelStore.availableModelIDs.map { id in
                        .item(shortName(id), checked: id == model.modelID) { model.modelID = id }
                    } + [.separator, .item(L("Другие модели…")) { model.showModelManager = true }]
                }
                Separator()
                MenuRow(title: L("Язык"), help: L("Язык речи в видео"),
                        value: WhisperEngine.languages.first { $0.code == model.language }?.name ?? model.language) {
                    WhisperEngine.languages.map { language in
                        .item(language.name, checked: language.code == model.language) { model.language = language.code }
                    }
                }
                Separator()
                Row(title: L("Подсказка"), help: L("Слова из видео, которые модель должна написать правильно: имена, названия, термины")) {
                    TextField("", text: $model.prompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity)
                        .focused($promptFocused)
                        // A placeholder of our own: the system one is too faint on black.
                        .overlay(alignment: .trailing) {
                            if model.prompt.isEmpty {
                                Text(L("Имена и термины"))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Palette.placeholder)
                                    .lineLimit(1)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(L("Подсказка"))
                        .accessibilityHint(L("Слова из видео, которые модель должна написать правильно: имена, названия, термины"))
                }
                // A click on the name of the row starts typing as well.
                .onTapGesture { promptFocused = true }
                Separator()
                SwitchRow(title: L("Распознавать сразу"), help: L("Распознавать речь, как только откроется видео"),
                          isOn: $model.autoTranscribe)
            }
            .card()
            HStack(spacing: 8) {
                Button {
                    model.requestTranscription()
                } label: {
                    Text(buttonTitle)
                        .frame(maxWidth: .infinity)
                }
                .appButton(.primary)
                .disabled(!model.canTranscribe)
                .help(buttonHelp)
                Button(L("Модели")) {
                    model.showModelManager = true
                }
                .appButton(.secondary)
                .help(L("Скачать или выбрать модели Whisper"))
            }
        }
    }

    private var modelTitle: String {
        modelStore.availableModelIDs.contains(model.modelID) ? shortName(model.modelID) : L("Не выбрана")
    }

    /// "Large v3 Turbo": the rows are narrow, and every model here is a Whisper one.
    private func shortName(_ id: String) -> String {
        let name = modelStore.displayName(for: id)
        return name.hasPrefix("Whisper ") ? String(name.dropFirst("Whisper ".count)) : name
    }

    private var buttonTitle: String {
        if model.activity?.kind == .transcribing { return L("Распознаю…") }
        return model.transcript == nil ? L("Распознать речь") : L("Распознать заново")
    }

    private var buttonHelp: String {
        if model.updateInProgress { return L("Сейчас ставится обновление, Subline скоро перезапустится") }
        if model.transcriptFromCache, let transcript = model.transcript {
            return L("Открыта сохранённая расшифровка (%@). Нажмите, чтобы распознать речь заново", "\(transcript.modelName)")
        }
        return L("Распознать речь в видео (⌘R)")
    }
}

/// Before the first model: what will be downloaded and one button.
private struct DownloadModelPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore

    var body: some View {
        let recommended = ModelCatalog.recommended
        let download = modelStore.downloads[recommended.id]
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                Row(title: L("Модель")) {
                    Text(recommended.name.replacingOccurrences(of: "Whisper ", with: ""))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                Separator()
                if let download {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressLine(value: download.verifying ? nil : download.fraction)
                        Text(progressText(download, total: recommended.sizeText))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(download.retryMessage == nil ? Palette.secondary : Palette.attention)
                            .lineLimit(1)
                            .help(download.retryMessage ?? "")
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: Metrics.rowHeight + 6)
                } else {
                    Row(title: L("Размер")) {
                        Text(recommended.sizeText)
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(Palette.secondary)
                    }
                }
            }
            .card()
            HStack(spacing: 8) {
                if download == nil {
                    Button {
                        modelStore.download(recommended)
                    } label: {
                        Text(L("Скачать модель"))
                            .frame(maxWidth: .infinity)
                    }
                    .appButton(.primary)
                    .help(L("Модель распознавания скачивается один раз, потом всё работает без интернета"))
                } else {
                    Button {
                        modelStore.cancelDownload(recommended.id)
                    } label: {
                        Text(L("Отменить"))
                            .frame(maxWidth: .infinity)
                    }
                    .appButton(.secondary)
                    .disabled(download?.verifying == true)
                }
                Button(L("Модели")) {
                    model.showModelManager = true
                }
                .appButton(.secondary)
                .help(L("Скачать или выбрать модели Whisper"))
            }
        }
    }

    private func progressText(_ state: ModelStore.DownloadState, total: String) -> String {
        if state.verifying { return L("Проверяю файл…") }
        if let retry = state.retryMessage { return retry }
        return L("%@%% из %@", "\(Int(state.fraction * 100))", "\(total)")
    }
}

// MARK: - Subtitles

private struct SubtitlesHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Text(L("Субтитры"))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if !model.cues.isEmpty {
                Text("\(model.cues.count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Palette.fill))
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if model.transcript != nil {
                MenuIconButton(help: L("Действия с субтитрами"), size: 24) {
                    [
                        .item(L("Сгруппировать выбранные"), enabled: !model.scopeCueIDs.isEmpty) { model.createGroup() },
                        .item(L("Разделить субтитр"), enabled: model.canSplit(model.targetCueID)) { model.splitCurrentCue() },
                        .separator,
                        .item(L("Пересобрать по пресету")) { model.rebuildCues() },
                    ]
                }
                .disabled(model.isBusy)
            }
        }
        .frame(height: 24)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.cues.count)
    }
}

/// The preset now cuts subtitles differently, but they were edited by hand.
private struct RebuildBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.attention)
            Text(L("Пресет изменился"))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(L("Пересобрать")) {
                model.rebuildCues()
            }
            .appButton(.secondary)
            .controlSize(.mini)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.attention.opacity(0.14)))
        .help(L("Строки в пресете изменились, а субтитры правились вручную. Пересборка нарежет их заново, ручные правки сбросятся"))
    }
}

private struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let transcribing = model.activity?.kind == .transcribing
        VStack(spacing: 10) {
            symbol(transcribing)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.card))
                .accessibilityHidden(true)
            Text(text(transcribing))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func symbol(_ transcribing: Bool) -> some View {
        if transcribing {
            RecognitionWave(animated: !reduceMotion)
                .frame(width: 24, height: 19)
        } else {
            Image(systemName: "captions.bubble")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Palette.secondary)
        }
    }

    /// Before a video the steps are in the middle of the window, so the list only says what will be here.
    private func text(_ transcribing: Bool) -> String {
        if transcribing { return L("Распознаю речь…") }
        if model.mediaURL == nil { return L("Здесь появятся субтитры") }
        if model.transcript != nil { return L("Речь не найдена") }
        return L("Нажмите «Распознать речь»")
    }
}

/// The waveform while speech is recognized: its bars brighten one after another. Core Animation plays this outside the
/// app, so it costs nothing per frame; a SwiftUI animation (or the system's variable color effect) would redraw the
/// whole window at the display rate and take most of a core away from Whisper. Still with Reduce Motion.
private struct RecognitionWave: NSViewRepresentable {
    var animated: Bool

    func makeNSView(context: Context) -> WaveView {
        WaveView()
    }

    func updateNSView(_ view: WaveView, context: Context) {
        view.animated = animated
    }

    final class WaveView: NSView {
        /// Heights of the bars, in points, like the waveform symbol.
        private static let heights: [CGFloat] = [6, 11, 17, 9, 14, 8, 5]
        private static let barWidth: CGFloat = 2
        private static let gap: CGFloat = 1.67
        private var bars: [CALayer] = []

        var animated = false {
            didSet { if animated != oldValue { animate() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            bars = Self.heights.map { _ in
                let bar = CALayer()
                bar.backgroundColor = NSColor.white.cgColor
                bar.cornerRadius = Self.barWidth / 2
                layer?.addSublayer(bar)
                return bar
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layout() {
            super.layout()
            let total = CGFloat(bars.count) * Self.barWidth + CGFloat(bars.count - 1) * Self.gap
            var x = (bounds.width - total) / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (bar, height) in zip(bars, Self.heights) {
                bar.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: Self.barWidth, height: height)
                x += Self.barWidth + Self.gap
            }
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            animate()
        }

        private func animate() {
            bars.forEach { $0.removeAllAnimations() }
            guard animated, window != nil else { return }
            let start = CACurrentMediaTime()
            for (index, bar) in bars.enumerated() {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.3
                pulse.duration = 0.5
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pulse.beginTime = start + Double(index) * 0.11
                pulse.fillMode = .backwards
                bar.add(pulse, forKey: "pulse")
            }
        }
    }
}

// MARK: - Groups

/// Groups of the video: a click edits the group's style, a right click offers more.
private struct GroupsBar: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: SubtitleGroup?
    @State private var newName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.groups) { group in
                    chip(group)
                }
                Button {
                    model.createGroup()
                } label: {
                    Label(model.groups.isEmpty ? L("Группа из выбранных") : L("Группа"), systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .disabled(model.scopeCueIDs.isEmpty)
                .opacity(model.scopeCueIDs.isEmpty ? 0.45 : 1)
                .help(L("Объединить выбранные субтитры (или тот, что на текущем кадре) в группу с общим стилем (⌘G)"))
            }
            .padding(2)
        }
        .alert(L("Название группы"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Название"), text: $newName)
            Button(L("Сохранить")) {
                if let group = renaming { model.renameGroup(group.id, to: newName) }
                renaming = nil
            }
            Button(L("Отмена"), role: .cancel) { renaming = nil }
        }
    }

    private func chip(_ group: SubtitleGroup) -> some View {
        let selected = model.scope == .group(group.id)
        return Button {
            model.selectGroup(group.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(group.color.color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(group.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text("\(model.cueCount(inGroup: group.id))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(selected ? group.color.color.opacity(0.3) : Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(selected ? group.color.color : Color.clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(L("Стиль группы «%@»", "\(group.name)"))
        .accessibilityLabel(L("Группа «%@»", "\(group.name)"))
        .accessibilityValue(L("Субтитров: %@", "\(model.cueCount(inGroup: group.id))"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(L("Переименовать…")) {
                newName = group.name
                renaming = group
            }
            Menu(L("Цвет")) {
                ForEach(Array(SubtitleGroup.palette.enumerated()), id: \.offset) { _, color in
                    Button {
                        model.recolorGroup(group.id, color)
                    } label: {
                        Text("●").foregroundColor(color.color)
                    }
                }
            }
            Button(L("Добавить выбранные в группу")) { model.addToGroup(group.id) }
                .disabled(model.scopeCueIDs.isEmpty)
            Divider()
            Button(L("Удалить группу"), role: .destructive) { model.deleteGroup(group.id) }
        }
    }
}

// MARK: - Subtitles list

private struct CueList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var playheadCue: PlayheadCue
    /// Playing or paused (the row under the playhead shows its tools only while the video stands).
    @ObservedObject var player: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrolling = ScrollActivity()

    var body: some View {
        let _ = RenderCount.hit("CueList")
        let cues = model.cues
        let lastIndex = cues.count - 1
        let current = playheadCue.id
        let playing = player.isPlaying
        let selected = model.selectedCueIDs
        let wordCueID = model.scope == .words ? model.wordSelection?.cueID : nil
        let editing = model.editingCueID
        let focus = model.textFocusRequest
        let clock = model.clockFormat
        let groups = model.groups
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        CueRow(model: model, cue: cue, isFirst: index == 0, isLast: index == lastIndex,
                               isCurrent: cue.id == current, isPlaying: cue.id == current && playing,
                               isSelected: selected.contains(cue.id) || cue.id == wordCueID,
                               isEditing: cue.id == editing,
                               group: cue.groupID.flatMap { id in groups.first { $0.id == id } },
                               groups: groups, fit: Self.rowFit(model.lineFit(for: cue)), clock: clock,
                               focusRequested: cue.id == focus)
                            .equatable()
                            .id(cue.id)
                            .onAppear { scrolling.shown.insert(cue.id) }
                            .onDisappear { scrolling.shown.remove(cue.id) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, Metrics.inset)
                .background(ScrollActivityReader(activity: scrolling))
            }
            .softTopEdge()
            .onChange(of: current) { id in
                follow(id, proxy)
            }
            .onChange(of: focus) { id in
                // Tab: the next subtitle comes into view, its text takes the typing.
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// What a row shows of how its text fits: the number of lines matters only when it is too many (the note under the
    /// text says it). A size slider changes the lines of many subtitles at every step; rows that still fit stay still.
    static func rowFit(_ fit: LineFit) -> LineFit {
        fit.overflows ? fit : LineFit(lines: 0, maxLines: fit.maxLines)
    }

    /// Keeps the subtitle under the playhead in view, smoothly and only when it has left the view: then it comes to
    /// the middle and the next ones play without moving the list. Not while the person scrolls the list themselves (and
    /// a moment after). While the playhead jumps quickly (scrubbing, stepping) the list waits until it settles, so it
    /// does not jump along with every step.
    private func follow(_ id: UUID?, _ proxy: ScrollViewProxy) {
        scrolling.pendingFollow?.cancel()
        guard let id, !scrolling.personScrolledRecently else { return }
        let now = CACurrentMediaTime()
        let quick = now - scrolling.lastFollowRequest < ScrollActivity.settle
        scrolling.lastFollowRequest = now
        if quick {
            let work = DispatchWorkItem { [scrolling] in
                MainActor.assumeIsolated {
                    guard !scrolling.personScrolledRecently, model.currentCueID == id else { return }
                    reveal(id, proxy, animated: true)
                }
            }
            scrolling.pendingFollow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ScrollActivity.settle, execute: work)
        } else {
            reveal(id, proxy, animated: true)
        }
    }

    private func reveal(_ id: UUID, _ proxy: ScrollViewProxy, animated: Bool) {
        guard !scrolling.isComfortablyShown(id, in: model.cues) else { return }
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// What following the playhead needs to know about the list: when the person last scrolled it (wheel, trackpad,
/// scroller), and which rows are on screen.
@MainActor
final class ScrollActivity {
    /// Following waits this long after the person's own scrolling.
    static let pause: CFTimeInterval = 2.5
    /// Jumps of the playhead closer than this are one move (scrubbing, stepping).
    static let settle: CFTimeInterval = 0.3
    var lastPersonScroll: CFTimeInterval = -.infinity
    var lastFollowRequest: CFTimeInterval = -.infinity
    var pendingFollow: DispatchWorkItem?
    /// Rows the list has made (those on screen and next to it).
    var shown = Set<UUID>()

    var personScrolledRecently: Bool { CACurrentMediaTime() - lastPersonScroll < Self.pause }

    /// The row is on screen with at least one row after it and before it (unless it is the first or the last).
    func isComfortablyShown(_ id: UUID, in cues: [Cue]) -> Bool {
        guard shown.contains(id), let index = cues.firstIndex(where: { $0.id == id }) else { return false }
        var first = Int.max
        var last = Int.min
        for (position, cue) in cues.enumerated() where shown.contains(cue.id) {
            first = min(first, position)
            last = max(last, position)
        }
        let top = first == 0 ? 0 : first + 1
        let bottom = last == cues.count - 1 ? last : last - 1
        return index >= top && index <= bottom
    }
}

/// Finds the scroll view around it and notes the scrolling the person does. Scrolling to a row from the code posts
/// none of these, so following the playhead does not count as the person's scroll.
private struct ScrollActivityReader: NSViewRepresentable {
    let activity: ScrollActivity

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(activity: activity)
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let activity: ScrollActivity
        private var observers: [NSObjectProtocol] = []
        private var wheelMonitor: Any?

        init(activity: ScrollActivity) {
            self.activity = activity
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: scrollView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.activity.lastPersonScroll = CACurrentMediaTime() }
                })
            }
            // A plain mouse wheel scrolls without live scroll notifications.
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak scrollView] event in
                MainActor.assumeIsolated {
                    guard let self, let scrollView, event.window === scrollView.window,
                          scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)) else { return }
                    self.activity.lastPersonScroll = CACurrentMediaTime()
                }
                return event
            }
        }

        private func stopWatching() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }

        override func removeFromSuperview() {
            stopWatching()
            super.removeFromSuperview()
        }
    }
}

/// One subtitle: timing on top, its text below, typed right in place. The subtitle under the playhead has a white bar
/// and a brighter start time; selected subtitles are lighter. While its text is typed in, the row has a white outline
/// and a "Done" button with the Esc key under the text.
///
/// The row draws only from the values it is given (`==` compares them) and does not watch the model, which it keeps
/// for its actions: a letter typed in another subtitle or a style change elsewhere leaves it alone, and the playhead
/// moving to the next subtitle redraws two rows, the one it left and the one it reached.
struct CueRow: View, Equatable {
    let model: AppModel
    let cue: Cue
    let isFirst: Bool
    let isLast: Bool
    let isCurrent: Bool
    /// The video plays through this row (only the row under the playhead gets true).
    let isPlaying: Bool
    let isSelected: Bool
    let isEditing: Bool
    let group: SubtitleGroup?
    /// For the "Добавить в группу" menu.
    let groups: [SubtitleGroup]
    let fit: LineFit
    let clock: ClockFormat
    let focusRequested: Bool
    @State private var hovering = false

    static func == (lhs: CueRow, rhs: CueRow) -> Bool {
        lhs.cue == rhs.cue && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast && lhs.isCurrent == rhs.isCurrent
            && lhs.isPlaying == rhs.isPlaying && lhs.isSelected == rhs.isSelected && lhs.isEditing == rhs.isEditing && lhs.group == rhs.group
            && lhs.groups == rhs.groups && lhs.fit == rhs.fit && lhs.clock == rhs.clock
            && lhs.focusRequested == rhs.focusRequested && lhs.model === rhs.model
    }

    var body: some View {
        let _ = RenderCount.hit("CueRow")
        let editing = isEditing
        let active = hovering || isSelected || editing || (isCurrent && !isPlaying)
        let words = CueText.words(cue.text)
        let canMoveFirst = !isFirst && !words.isEmpty
        let canMoveLast = !isLast && !words.isEmpty
        HStack(alignment: .top, spacing: 8) {
            // The group is said in words too (VoiceOver, the tooltip): the color alone does not carry it.
            Capsule()
                .fill(group?.color.color ?? (isCurrent ? Color.white : Color.clear))
                .frame(width: 3)
                .padding(.vertical, 2)
                .help(group.map { L("Группа «%@»", "\($0.name)") } ?? "")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    TimeField(value: cue.start, format: clock, label: L("Начало"), highlighted: isCurrent,
                              onBeginEditing: { model.select(cue) }) { model.updateCueTiming(cue.id, start: $0) }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Palette.tertiary)
                        .accessibilityHidden(true)
                    TimeField(value: cue.end, format: clock, label: L("Конец"),
                              onBeginEditing: { model.select(cue) }) { model.updateCueTiming(cue.id, end: $0) }
                    if cue.hasCustomStyle {
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.secondary)
                            .help(L("У субтитра свой стиль"))
                            .accessibilityLabel(L("У субтитра свой стиль"))
                    }
                    Spacer(minLength: 0)
                    RowTools(active: active, canMoveFirst: canMoveFirst, canMoveLast: canMoveLast,
                             moveFirst: { [model, id = cue.id] in model.moveFirstWordToPrevious(id) },
                             moveLast: { [model, id = cue.id] in model.moveLastWordToNext(id) },
                             entries: { [model, id = cue.id] in CueRow.entries(model: model, id: id) })
                        .equatable()
                }
                CueTextCell(model: model, cue: cue, allowsLineBreaks: fit.maxLines > 1, isEditing: isEditing,
                            focusRequested: focusRequested, menuEntries: { textMenuEntries })
                if fit.overflows {
                    OverflowNote(fit: fit) { model.splitToFit(cue.id) }
                }
                if editing {
                    EditingHint(allowsLineBreaks: fit.maxLines > 1) { model.finishTextEditing() }
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background(editing)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(editing ? 0.7 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.clickRow(cue, modifiers: NSEvent.modifierFlags)
        }
        .contextMenu { MenuEntriesView(entries: entries) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: editing)
        // VoiceOver: the row says its times, group and state, and offers the commands of the ⋯ menu.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle(clock))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                if entry.kind == .item, entry.children.isEmpty, entry.enabled, let action = entry.action {
                    Button(entry.title, action: action)
                }
            }
        }
    }

    private func accessibilityTitle(_ clock: ClockFormat) -> String {
        var parts = [L("Субтитр с %@ до %@", clock.string(cue.start), clock.string(cue.end))]
        if let group { parts.append(L("Группа «%@»", "\(group.name)")) }
        if isCurrent { parts.append(L("на текущем кадре")) }
        return parts.joined(separator: ", ")
    }

    private func background(_ editing: Bool) -> Color {
        if editing { return Color.white.opacity(0.1) }
        if isSelected { return Color.white.opacity(0.15) }
        if isCurrent { return Color.white.opacity(0.08) }
        return Color.white.opacity(hovering ? 0.04 : 0)
    }

    /// Moving words and cutting: in the ⋯ menu, the right-click menu of the row and the menu of the text. A cut goes
    /// at the text caret while the text is typed in, else at the playhead inside the subtitle, else where both halves
    /// fit best. Built from the model as it is when the menu opens: a row left alone by `==` may hold older values.
    static func wordEntries(model: AppModel, id: UUID, atCaret: Bool) -> [MenuEntry] {
        guard let index = model.cues.firstIndex(where: { $0.id == id }) else { return [] }
        let words = CueText.words(model.cues[index].text)
        let isFirst = index == 0
        let isLast = index == model.cues.count - 1
        return [
            .item(L("Перенести первое слово в предыдущий субтитр"), enabled: !isFirst && !words.isEmpty) {
                model.moveFirstWordToPrevious(id)
            },
            .item(L("Перенести последнее слово в следующий субтитр"), enabled: !isLast && !words.isEmpty) {
                model.moveLastWordToNext(id)
            },
            .item(atCaret ? L("Разделить по текстовому курсору") : L("Разделить субтитр"), enabled: words.count > 1) {
                model.splitCue(id)
            },
            .item(L("Объединить со следующим"), enabled: !isLast) { model.mergeWithNext(id) },
        ]
    }

    /// The menu of the text is built on the right click, while typing goes on.
    private var textMenuEntries: [MenuEntry] {
        Self.wordEntries(model: model, id: cue.id, atCaret: model.editingCueID == cue.id)
    }

    private var entries: [MenuEntry] {
        Self.entries(model: model, id: cue.id)
    }

    /// The ⋯ menu and the right-click menu of a row.
    static func entries(model: AppModel, id: UUID) -> [MenuEntry] {
        guard let cue = model.cues.first(where: { $0.id == id }) else { return [] }
        var items: [MenuEntry] = [.item(L("Перейти к началу")) { model.select(cue, keepPlaying: true) }]
        items += wordEntries(model: model, id: id, atCaret: false)
        items += [
            .item(L("Добавить субтитр после")) { model.insertCue(after: id) },
            .separator,
            .item(L("Новая группа из выбранных")) {
                if !model.selectedCueIDs.contains(id) { model.clickRow(cue, modifiers: []) }
                model.createGroup()
            },
        ]
        if !model.groups.isEmpty {
            items.append(.submenu(L("Добавить в группу"), model.groups.map { group in
                .item(group.name) {
                    if !model.selectedCueIDs.contains(id) { model.clickRow(cue, modifiers: []) }
                    model.addToGroup(group.id)
                }
            }))
        }
        if cue.groupID != nil {
            items.append(.item(L("Убрать из группы")) { model.removeFromGroup([id]) })
        }
        if cue.hasCustomStyle {
            items.append(.item(L("Сбросить стиль субтитра")) {
                model.clickRow(cue, modifiers: [])
                model.scope = .cues
                model.resetScopeStyle()
                model.modifyWordStylesReset(id)
            })
        }
        items += [.separator, .item(L("Удалить")) { model.deleteCue(id) }]
        return items
    }
}

/// The buttons at the end of a row's times. Moving words shows on the row being worked with (under the pointer, selected,
/// typed in, or under the playhead while the video stands), and those buttons are made only then: in every row of a
/// long list they cost more than the rest of it. The ⋯ menu is always there, quietly. Redrawn only when what it shows
/// changes, not on every letter typed in the row.
private struct RowTools: View, Equatable {
    let active: Bool
    let canMoveFirst: Bool
    let canMoveLast: Bool
    let moveFirst: () -> Void
    let moveLast: () -> Void
    let entries: () -> [MenuEntry]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.active == rhs.active && lhs.canMoveFirst == rhs.canMoveFirst && lhs.canMoveLast == rhs.canMoveLast
    }

    var body: some View {
        HStack(spacing: 0) {
            if active {
                IconButton(symbol: "arrow.up.to.line", help: L("Первое слово в предыдущий субтитр (⌥⌘↑)"),
                           size: 20, filled: false, action: moveFirst)
                    .disabled(!canMoveFirst)
                IconButton(symbol: "arrow.down.to.line", help: L("Последнее слово в следующий субтитр (⌥⌘↓)"),
                           size: 20, filled: false, action: moveLast)
                    .disabled(!canMoveLast)
            } else {
                Color.clear
                    .frame(width: 48, height: 24)
                    .accessibilityHidden(true)
            }
            MenuIconButton(help: L("Действия с субтитром"), size: 20, filled: false, entries: entries)
                .opacity(active ? 1 : 0.45)
        }
    }
}

/// The text of a subtitle in its row. Plain text until the person clicks into it (or Tab brings typing here); then
/// the editor (an AppKit text view) takes its place with the caret where the click was. A text view in every row made
/// each row take milliseconds to appear while the list scrolled. The plain text is sized the way the editor lays the
/// text out, so the row keeps its height when one replaces the other. A click with ⇧ or ⌘ selects the row instead.
private struct CueTextCell: View {
    let model: AppModel
    let cue: Cue
    let allowsLineBreaks: Bool
    let isEditing: Bool
    let focusRequested: Bool
    let menuEntries: () -> [MenuEntry]
    @State private var editorShown = false
    @State private var caret: Int?
    @State private var width = TextWidth()

    var body: some View {
        Group {
            if editorShown || isEditing || focusRequested {
                CueTextEditor(cueID: cue.id, text: cue.text, allowsLineBreaks: allowsLineBreaks,
                              menuEntries: menuEntries,
                              onBegin: { model.beginTextEditing(cue) },
                              onChange: { model.editCueText(cue.id, $0) },
                              onCaret: { offset in
                                  model.textCaret = TextCaret(cueID: cue.id, offset: offset, text: model.cues.first { $0.id == cue.id }?.text ?? cue.text,
                                                              time: Date())
                              },
                              onEnd: {
                                  model.endTextEditing(cue.id)
                                  editorShown = false
                                  caret = nil
                              },
                              onTab: { forward in model.editText(after: cue.id, forward: forward) },
                              focusRequested: focusRequested || (editorShown && !isEditing),
                              caretOnFocus: caret,
                              onFocusTaken: { if model.textFocusRequest == cue.id { model.textFocusRequest = nil } })
            } else {
                EditorSizedText(text: cue.text, width: width) {
                    Text(cue.text)
                        .font(Font(CueTextEditor.font as CTFont))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    if !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty {
                        model.clickRow(cue, modifiers: NSEvent.modifierFlags)
                        return
                    }
                    caret = CueTextEditor.characterIndex(in: cue.text, width: width.value, at: location)
                    editorShown = true
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Текст субтитра"))
                .accessibilityValue(cue.text)
                .accessibilityAction { editorShown = true }
            }
        }
        .overlay(alignment: .topLeading) {
            if cue.text.isEmpty {
                Text(L("Текст субтитра"))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.placeholder)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The width the text was last laid out at (for finding the character under a click).
@MainActor
private final class TextWidth {
    var value: CGFloat = 0
}

/// Gives the text the height the editor would lay it out at, and notes the width.
private struct EditorSizedText: Layout {
    let text: String
    let width: TextWidth

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 120
        // SwiftUI lays out on the main thread.
        return CGSize(width: width, height: MainActor.assumeIsolated { CueTextEditor.height(of: text, width: width) })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        MainActor.assumeIsolated { width.value = bounds.width }
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

/// The text is longer than the lines of the style allow: said plainly under it, with the way out.
struct OverflowNote: View {
    let fit: LineFit
    let split: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
            Text(Self.title(fit))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Button(L("Разделить"), action: split)
                .appButton(.secondary)
                .controlSize(.mini)
                .help(L("Разделить субтитр на два, каждый в заданное число строк. Время поделится по словам"))
        }
        .foregroundStyle(Palette.attention)
        .help(Self.help(fit))
    }

    static func title(_ fit: LineFit) -> String {
        switch fit.maxLines {
        case 1: return L("Не помещается в одну строку")
        case 2: return L("Не помещается в две строки")
        default: return L("Не помещается в три строки")
        }
    }

    /// The same over the video.
    static func pillTitle(_ fit: LineFit) -> String {
        switch fit.maxLines {
        case 1: return L("Субтитр не помещается в одну строку")
        case 2: return L("Субтитр не помещается в две строки")
        default: return L("Субтитр не помещается в три строки")
        }
    }

    static func help(_ fit: LineFit) -> String {
        L("При этом шрифте и ширине блока текст не умещается в заданные строки, и в видео он займёт больше строк. Разделите субтитр на два или сократите текст")
    }
}

/// Under the text being typed: how to finish, and a button that does it.
private struct EditingHint: View {
    let allowsLineBreaks: Bool
    let done: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: done) {
                HStack(spacing: 5) {
                    Text(L("Готово"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(verbatim: "esc")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.black.opacity(0.35)))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.black)
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .frame(height: 20)
                .background(Capsule().fill(Brand.mark))
                // The click target is taller than the capsule.
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .accessibilityLabel(L("Готово"))
            Text(allowsLineBreaks ? L("или Return. Новая строка: ⌥Return") : L("или Return"))
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .help(L("Правка заканчивается клавишей Esc или Return и щелчком мимо текста, набранное остаётся, и пробел снова запускает видео. Tab переходит к тексту следующего субтитра"))
    }
}

/// Menu entries as SwiftUI menu items (for right-click menus).
struct MenuEntriesView: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry.kind {
            case .separator:
                Divider()
            case .header:
                Text(entry.title)
            case .item:
                if entry.children.isEmpty {
                    Button(entry.title) { entry.action?() }
                        .disabled(!entry.enabled)
                } else {
                    Menu(entry.title) { MenuEntriesView(entries: entry.children) }
                        .disabled(!entry.enabled)
                }
            }
        }
    }
}
