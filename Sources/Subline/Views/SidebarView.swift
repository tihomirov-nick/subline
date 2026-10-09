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
                    CueList()
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.cues) { cue in
                        CueRow(cue: cue,
                               isCurrent: cue.id == model.currentCueID,
                               isSelected: model.selectedCueIDs.contains(cue.id) || (model.scope == .words && model.wordSelection?.cueID == cue.id),
                               group: model.group(cue.groupID))
                            .id(cue.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, Metrics.inset)
            }
            .softTopEdge()
            .onChange(of: model.currentCueID) { id in
                // Keep the subtitle under the playhead in view.
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .onChange(of: model.textFocusRequest) { id in
                // Tab: the next subtitle comes into view, its text takes the typing.
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

/// One subtitle: timing on top, its text below, typed right in place. The subtitle under the playhead has a white bar
/// and a brighter start time; selected subtitles are lighter. While its text is typed in, the row has a white outline
/// and a "Done" button with the Esc key under the text.
struct CueRow: View {
    @EnvironmentObject var model: AppModel
    let cue: Cue
    let isCurrent: Bool
    let isSelected: Bool
    let group: SubtitleGroup?
    @State private var hovering = false

    var body: some View {
        let editing = model.editingCueID == cue.id
        let fit = model.lineFit(for: cue)
        let active = hovering || isCurrent || isSelected || editing
        let clock = model.clockFormat
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
                    HStack(spacing: 0) {
                        // Moving words shows on the row being worked with; the ⋯ menu is always there, quietly.
                        Group {
                            IconButton(symbol: "arrow.up.to.line", help: L("Первое слово в предыдущий субтитр (⌥⌘↑)"),
                                       size: 20, filled: false) {
                                model.moveFirstWordToPrevious(cue.id)
                            }
                            .disabled(!model.canMoveFirstWordToPrevious(cue.id))
                            IconButton(symbol: "arrow.down.to.line", help: L("Последнее слово в следующий субтитр (⌥⌘↓)"),
                                       size: 20, filled: false) {
                                model.moveLastWordToNext(cue.id)
                            }
                            .disabled(!model.canMoveLastWordToNext(cue.id))
                        }
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                        MenuIconButton(help: L("Действия с субтитром"), size: 20, filled: false) { entries }
                            .opacity(active ? 1 : 0.45)
                    }
                }
                CueTextEditor(cueID: cue.id, text: cue.text, allowsLineBreaks: fit.maxLines > 1,
                              menuEntries: { textMenuEntries },
                              onBegin: { model.beginTextEditing(cue) },
                              onChange: { model.editCueText(cue.id, $0) },
                              onCaret: { offset in
                                  model.textCaret = TextCaret(cueID: cue.id, offset: offset, text: model.cues.first { $0.id == cue.id }?.text ?? cue.text,
                                                              time: Date())
                              },
                              onEnd: { model.endTextEditing(cue.id) },
                              onTab: { forward in model.editText(after: cue.id, forward: forward) },
                              focusRequested: model.textFocusRequest == cue.id,
                              onFocusTaken: { if model.textFocusRequest == cue.id { model.textFocusRequest = nil } })
                    .overlay(alignment: .topLeading) {
                        if cue.text.isEmpty {
                            Text(L("Текст субтитра"))
                                .font(.system(size: 13.5))
                                .foregroundStyle(Palette.placeholder)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
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
    /// fit best.
    private func wordEntries(atCaret: Bool) -> [MenuEntry] {
        [
            .item(L("Перенести первое слово в предыдущий субтитр"), enabled: model.canMoveFirstWordToPrevious(cue.id)) {
                model.moveFirstWordToPrevious(cue.id)
            },
            .item(L("Перенести последнее слово в следующий субтитр"), enabled: model.canMoveLastWordToNext(cue.id)) {
                model.moveLastWordToNext(cue.id)
            },
            .item(atCaret ? L("Разделить по текстовому курсору") : L("Разделить субтитр"), enabled: model.canSplit(cue.id)) {
                model.splitCue(cue.id)
            },
            .item(L("Объединить со следующим"), enabled: model.canMergeWithNext(cue.id)) { model.mergeWithNext(cue.id) },
        ]
    }

    /// The menu of the text is built on the right click, while typing goes on.
    private var textMenuEntries: [MenuEntry] {
        wordEntries(atCaret: model.editingCueID == cue.id)
    }

    private var entries: [MenuEntry] {
        var items: [MenuEntry] = [.item(L("Перейти к началу")) { model.select(cue, keepPlaying: true) }]
        items += wordEntries(atCaret: false)
        items += [
            .item(L("Добавить субтитр после")) { model.insertCue(after: cue.id) },
            .separator,
            .item(L("Новая группа из выбранных")) {
                if !model.selectedCueIDs.contains(cue.id) { model.clickRow(cue, modifiers: []) }
                model.createGroup()
            },
        ]
        if !model.groups.isEmpty {
            items.append(.submenu(L("Добавить в группу"), model.groups.map { group in
                .item(group.name) {
                    if !model.selectedCueIDs.contains(cue.id) { model.clickRow(cue, modifiers: []) }
                    model.addToGroup(group.id)
                }
            }))
        }
        if cue.groupID != nil {
            items.append(.item(L("Убрать из группы")) { model.removeFromGroup([cue.id]) })
        }
        if cue.hasCustomStyle {
            items.append(.item(L("Сбросить стиль субтитра")) {
                model.clickRow(cue, modifiers: [])
                model.scope = .cues
                model.resetScopeStyle()
                model.modifyWordStylesReset(cue.id)
            })
        }
        items += [.separator, .item(L("Удалить")) { model.deleteCue(cue.id) }]
        return items
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
