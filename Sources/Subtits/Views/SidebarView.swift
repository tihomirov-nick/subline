import SwiftUI
import AppKit
import SubtitsCore

/// Left sidebar: speech recognition and the subtitles (the navigator of the document).
struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            RecognitionPanel()
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 14)
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 1)
                .padding(.horizontal, 16)
            header
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            if model.needsRebuild {
                rebuildBanner
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            if !model.cues.isEmpty {
                GroupsBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if model.cues.isEmpty {
                emptyState
            } else {
                CueList()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(L("Субтитры"))
                .font(.system(size: 15, weight: .bold))
            if !model.cues.isEmpty {
                Text("\(model.cues.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.quietFill))
            }
            Spacer()
            if model.transcript != nil {
                Menu {
                    Button(L("Сгруппировать выбранные")) { model.createGroup() }
                        .disabled(model.scopeCueIDs.isEmpty)
                    Button(L("Разделить текущий субтитр по курсору")) { model.splitCurrentCue() }
                        .disabled(model.currentCue == nil)
                    Divider()
                    Button(L("Пересобрать по настройкам пресета")) { model.rebuildCues() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                }
                .circleMenu()
                .disabled(model.isBusy)
                .help(L("Действия с субтитрами"))
            }
        }
        .frame(minHeight: 28)
    }

    private var rebuildBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Строки в пресете изменились, а субтитры вы уже правили вручную."))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Пересобрать (правки сбросятся)")) {
                    model.rebuildCues()
                }
                .glassButton()
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous).fill(Color.orange.opacity(0.13)))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            EmptySymbol(transcribing: model.activity?.kind == .transcribing)
            // No fixedSize here: while sizing the split view the sidebar is offered a tiny width, and a
            // fixed-height wrapping text would then demand a huge window.
            Text(emptyText)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var emptyText: String {
        if model.activity?.kind == .transcribing { return L("Идёт распознавание речи…") }
        if model.mediaURL == nil { return L("Откройте видео, и здесь появится распознанный текст. Его можно править прямо в списке.") }
        if model.transcript != nil { return L("Речь не найдена.") }
        return L("Нажмите «Распознать речь».")
    }
}

/// Symbol of the empty list in a soft circle; the waveform pulses while speech is being recognized.
private struct EmptySymbol: View {
    let transcribing: Bool

    var body: some View {
        let image = Image(systemName: transcribing ? "waveform" : "captions.bubble")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(transcribing ? Color.accentColor : Color.secondary)
        Group {
            if #available(macOS 14.0, *) {
                image.symbolEffect(.variableColor.iterative, isActive: transcribing)
            } else {
                image
            }
        }
        .frame(width: 60, height: 60)
        .background(Circle().fill(Color.quietFill))
    }
}

// MARK: - Recognition

private struct RecognitionPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
                Text(L("Распознавание"))
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button(L("Модели")) {
                    model.showModelManager = true
                }
                .glassButton()
                .controlSize(.small)
                .help(L("Скачать или выбрать модели Whisper"))
            }
            .padding(.leading, 4)
            if modelStore.hasAnyModel {
                VStack(alignment: .leading, spacing: 0) {
                    MenuRow(symbol: "cpu", title: L("Модель"), value: modelStore.availableModelIDs.contains(model.modelID)
                            ? modelStore.displayName(for: model.modelID) : L("Модель не выбрана")) {
                        Picker("", selection: $model.modelID) {
                            ForEach(modelStore.availableModelIDs, id: \.self) { id in
                                Text(modelStore.displayName(for: id)).tag(id)
                            }
                            if !modelStore.availableModelIDs.contains(model.modelID) {
                                Text(L("Модель не выбрана")).tag(model.modelID)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .help(L("Модель распознавания"))
                    rowDivider
                    MenuRow(symbol: "globe", title: L("Язык"),
                            value: WhisperEngine.languages.first { $0.code == model.language }?.name ?? model.language) {
                        Picker("", selection: $model.language) {
                            ForEach(WhisperEngine.languages, id: \.code) { language in
                                Text(language.name).tag(language.code)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .help(L("Язык речи в видео"))
                    rowDivider
                    DisclosureGroup(isExpanded: $showOptions) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(L("Например, имена и названия брендов"), text: $model.prompt, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .lineLimit(1...3)
                                .help(L("Слова из видео, которые модель должна написать правильно"))
                            Toggle(L("Распознавать сразу после открытия"), isOn: $model.autoTranscribe)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                        }
                        .padding(.top, 8)
                    } label: {
                        Text(L("Подсказка и параметры"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .card(fill: .quietFill)
                Button {
                    model.startTranscription()
                } label: {
                    Label(buttonTitle, systemImage: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
                .disabled(model.media == nil || model.isBusy)
                if model.transcriptFromCache, let transcript = model.transcript {
                    Text(L("Открыта сохранённая расшифровка · %@", "\(transcript.modelName)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                }
            } else {
                DownloadModelCard()
            }
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 1)
            .padding(.leading, 38)
    }

    private var buttonTitle: String {
        if model.activity?.kind == .transcribing { return L("Распознаю…") }
        return model.transcript == nil ? L("Распознать речь") : L("Распознать заново")
    }
}

/// Settings-style row: icon and title on the left, the current value with a menu on the right.
private struct MenuRow<Items: View>: View {
    let symbol: String
    let title: String
    let value: String
    @ViewBuilder var items: Items

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            ValueMenu(value: value) { items }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
    }
}

private struct DownloadModelCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore

    var body: some View {
        let recommended = ModelCatalog.recommended
        let download = modelStore.downloads[recommended.id]
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Для распознавания нужна модель Whisper. Она скачивается один раз и работает без интернета."))
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let download {
                ProgressView(value: download.fraction)
                Text(download.verifying ? L("Проверка файла…") : download.retryMessage ?? L("%@%% из %@", "\(Int(download.fraction * 100))", "\(recommended.sizeText)"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(download.retryMessage == nil ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    modelStore.download(recommended)
                } label: {
                    Label(L("Скачать %@ · %@", "\(recommended.name)", "\(recommended.sizeText)"), systemImage: "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous).fill(Color.accentColor.opacity(0.12)))
    }
}

// MARK: - Groups

/// Groups of the video: click to edit the group style, right-click for more.
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
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(model.scopeCueIDs.isEmpty)
                .help(L("Объединить выбранные субтитры (или тот, что под курсором) в группу с общим стилем (⌘G)"))
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
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
                    .frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text("\(model.cueCount(inGroup: group.id))")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(selected ? group.color.color.opacity(0.3) : Color.quietFill))
            .overlay(Capsule().strokeBorder(selected ? group.color.color : Color.clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
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

// MARK: - Subtitles

private struct CueList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.cues) { cue in
                    CueRow(cue: cue,
                           isCurrent: cue.id == model.currentCueID,
                           isSelected: model.selectedCueIDs.contains(cue.id) || (model.scope == .words && model.wordSelection?.cueID == cue.id),
                           group: model.group(cue.groupID))
                        .id(cue.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: model.currentCueID) { id in
                // Keep the subtitle under the playhead in view.
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

/// One subtitle: timing on top, editable text below. The subtitle under the playhead is marked with
/// the accent bar and its start time; selected subtitles are tinted with the accent color.
private struct CueRow: View {
    @EnvironmentObject var model: AppModel
    let cue: Cue
    let isCurrent: Bool
    let isSelected: Bool
    let group: SubtitleGroup?
    @State private var hovering = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(group?.color.color ?? (isCurrent ? Color.accentColor : Color.clear))
                .frame(width: 3)
                .padding(.vertical, 3)
                .help(group.map { L("Группа «%@»", "\($0.name)") } ?? "")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    TimeField(value: cue.start, tint: isCurrent ? Color.accentColor : nil,
                              onBeginEditing: { model.select(cue) }) { model.updateCueTiming(cue.id, start: $0) }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TimeField(value: cue.end, onBeginEditing: { model.select(cue) }) { model.updateCueTiming(cue.id, end: $0) }
                    if cue.hasCustomStyle {
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.accentColor)
                            .help(L("У субтитра свой стиль"))
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button(L("Перейти к началу")) { model.select(cue, keepPlaying: true) }
                        Button(L("Объединить со следующим")) { model.mergeWithNext(cue.id) }
                        Button(L("Добавить субтитр после")) { model.insertCue(after: cue.id) }
                        Divider()
                        Button(L("Новая группа из выбранных")) {
                            if !model.selectedCueIDs.contains(cue.id) { model.clickRow(cue, modifiers: []) }
                            model.createGroup()
                        }
                        if !model.groups.isEmpty {
                            Menu(L("Добавить в группу")) {
                                ForEach(model.groups) { group in
                                    Button(group.name) {
                                        if !model.selectedCueIDs.contains(cue.id) { model.clickRow(cue, modifiers: []) }
                                        model.addToGroup(group.id)
                                    }
                                }
                            }
                        }
                        if cue.groupID != nil {
                            Button(L("Убрать из группы")) { model.removeFromGroup([cue.id]) }
                        }
                        if cue.hasCustomStyle {
                            Button(L("Сбросить стиль субтитра")) {
                                model.clickRow(cue, modifiers: [])
                                model.scope = .cues
                                model.resetScopeStyle()
                                model.modifyWordStylesReset(cue.id)
                            }
                        }
                        Divider()
                        Button(L("Удалить"), role: .destructive) { model.deleteCue(cue.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .opacity(hovering || isCurrent || isSelected ? 1 : 0)
                }
                TextField(L("Текст субтитра"), text: Binding(get: { cue.text }, set: { model.updateCueText(cue.id, $0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...6)
                    .focused($editing)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Look.innerRadius, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.clickRow(cue, modifiers: NSEvent.modifierFlags)
        }
        .onHover { hovering = $0 }
        .onChange(of: editing) { isEditing in
            // Clicking into the text also goes to the start of the subtitle and pauses, so it stays on screen.
            if isEditing { model.select(cue) }
        }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.24) }
        if isCurrent { return Color.accentColor.opacity(0.1) }
        return hovering ? Color.primary.opacity(0.05) : Color.clear
    }
}
