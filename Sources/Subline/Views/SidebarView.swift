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

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                Row(title: L("Модель")) {
                    ValueMenu(value: modelTitle) {
                        modelStore.availableModelIDs.map { id in
                            .item(shortName(id), checked: id == model.modelID) { model.modelID = id }
                        } + [.separator, .item(L("Другие модели…")) { model.showModelManager = true }]
                    }
                }
                Separator()
                Row(title: L("Язык"), help: L("Язык речи в видео")) {
                    ValueMenu(value: WhisperEngine.languages.first { $0.code == model.language }?.name ?? model.language) {
                        WhisperEngine.languages.map { language in
                            .item(language.name, checked: language.code == model.language) { model.language = language.code }
                        }
                    }
                }
                Separator()
                Row(title: L("Подсказка"), help: L("Слова из видео, которые модель должна написать правильно: имена, названия, термины")) {
                    TextField(L("Имена и термины"), text: $model.prompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity)
                }
                Separator()
                Row(title: L("Сразу после открытия"), help: L("Распознавать речь, как только откроется видео")) {
                    Switch(isOn: $model.autoTranscribe)
                }
            }
            .card()
            HStack(spacing: 8) {
                Button {
                    model.startTranscription()
                } label: {
                    Text(buttonTitle)
                        .frame(maxWidth: .infinity)
                }
                .appButton(.primary)
                .disabled(model.media == nil || model.isBusy || model.updateInProgress)
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
                        .item(L("Разделить субтитр по курсору"), enabled: model.currentCue != nil) { model.splitCurrentCue() },
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

    private func text(_ transcribing: Bool) -> String {
        if transcribing { return L("Распознаю речь…") }
        if model.mediaURL == nil { return L("Откройте видео") }
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
                .help(L("Объединить выбранные субтитры (или тот, что под курсором) в группу с общим стилем (⌘G)"))
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
        }
    }
}

/// One subtitle: timing on top, editable text below. The subtitle under the playhead has a white bar and a brighter
/// start time; selected subtitles are lighter.
private struct CueRow: View {
    @EnvironmentObject var model: AppModel
    let cue: Cue
    let isCurrent: Bool
    let isSelected: Bool
    let group: SubtitleGroup?
    @State private var hovering = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(group?.color.color ?? (isCurrent ? Color.white : Color.clear))
                .frame(width: 3)
                .padding(.vertical, 2)
                .help(group.map { L("Группа «%@»", "\($0.name)") } ?? "")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    TimeField(value: cue.start, highlighted: isCurrent,
                              onBeginEditing: { model.select(cue) }) { model.updateCueTiming(cue.id, start: $0) }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Palette.tertiary)
                    TimeField(value: cue.end, onBeginEditing: { model.select(cue) }) { model.updateCueTiming(cue.id, end: $0) }
                    if cue.hasCustomStyle {
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.secondary)
                            .help(L("У субтитра свой стиль"))
                    }
                    Spacer(minLength: 0)
                    MenuIconButton(help: L("Действия с субтитром"), size: 20, filled: false) { entries }
                        .opacity(hovering || isCurrent || isSelected ? 1 : 0)
                }
                TextField(L("Текст субтитра"), text: Binding(get: { cue.text }, set: { model.updateCueText(cue.id, $0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...6)
                    .focused($editing)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
        .contentShape(Rectangle())
        .onTapGesture {
            model.clickRow(cue, modifiers: NSEvent.modifierFlags)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onChange(of: editing) { isEditing in
            // Clicking into the text also goes to the start of the subtitle and pauses, so it stays on screen.
            if isEditing { model.select(cue) }
        }
    }

    private var background: Color {
        if isSelected { return Color.white.opacity(0.15) }
        if isCurrent { return Color.white.opacity(0.08) }
        return Color.white.opacity(hovering ? 0.04 : 0)
    }

    private var entries: [MenuEntry] {
        var items: [MenuEntry] = [
            .item(L("Перейти к началу")) { model.select(cue, keepPlaying: true) },
            .item(L("Объединить со следующим")) { model.mergeWithNext(cue.id) },
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
