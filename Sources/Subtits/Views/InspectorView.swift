import SwiftUI
import SubtitsCore

/// Right panel: the style of the current scope (all subtitles, a group, subtitles or words).
/// Sizes and positions are in pixels of the current frame. Grouped cards on a grouped background,
/// as in iOS Settings; the controls at the top choose what the cards change.
struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        BarredScroll {
            VStack(spacing: 12) {
                PresetBar()
                ScopeBar()
                SegmentedTrack(selection: $model.inspectorTab, values: InspectorTab.allCases) { tab, selected in
                    Text(tab.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(height: 24)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
        } content: {
            VStack(spacing: 0) {
                switch effectiveTab {
                case .text: TextTab()
                case .layout: LayoutTab()
                case .effects: EffectsTab()
                }
            }
            .padding(.bottom, 24)
        }
        .frame(width: 300)
        .background(Color.groupedBackground)
    }

    /// Words have no layout of their own.
    private var effectiveTab: InspectorTab {
        model.scope == .words && model.inspectorTab == .layout ? .text : model.inspectorTab
    }
}

// MARK: - Preset

private struct PresetBar: View {
    @EnvironmentObject var model: AppModel
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 8) {
            // Hugs the preset name, truncates a long one.
            ViewThatFits(in: .horizontal) {
                presetPicker.fixedSize()
                presetPicker
            }
            Spacer(minLength: 0)
            Menu {
                Button(L("Новый пресет")) { model.addPreset() }
                Button(L("Дублировать")) { model.duplicatePreset() }
                Button(L("Переименовать…")) {
                    newName = model.preset.name
                    isRenaming = true
                }
                Divider()
                Button(L("Экспортировать пресет…")) { model.exportPresets(all: false) }
                Button(L("Экспортировать все пресеты…")) { model.exportPresets(all: true) }
                Button(L("Импортировать пресеты…")) { model.importPresets() }
                Divider()
                Button(L("Восстановить стандартные пресеты")) { model.restoreBuiltInPresets() }
                Button(L("Удалить пресет…"), role: .destructive) { confirmDelete = true }
                    .disabled(model.presets.count < 2)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
            }
            .circleMenu()
            .controlSize(.large)
            .help(L("Действия с пресетами"))
        }
        .confirmationDialog(L("Удалить пресет «%@»?", "\(model.preset.name)"), isPresented: $confirmDelete) {
            Button(L("Удалить"), role: .destructive) { model.deletePreset() }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Это действие нельзя отменить."))
        }
        .alert(L("Название пресета"), isPresented: $isRenaming) {
            TextField(L("Название"), text: $newName)
            Button(L("Сохранить")) { model.renamePreset(to: newName) }
            Button(L("Отмена"), role: .cancel) {}
        }
    }

    private var presetPicker: some View {
        Picker(L("Пресет"), selection: $model.selectedPresetID) {
            ForEach(model.presets) { preset in
                Text(preset.name).tag(preset.id)
            }
        }
        .labelsHidden()
        .controlSize(.large)
        .help(L("Пресет хранит общий стиль всех субтитров"))
    }
}

// MARK: - Scope

private enum ScopeKind: Hashable { case all, group, cues, words }

/// Where the changes go: the preset, a group, subtitles or words.
private struct ScopeBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedTrack(selection: Binding(get: { currentKind }, set: { select($0) }),
                           values: [.all, .group, .cues, .words],
                           radius: 9,
                           isEnabled: isEnabled,
                           help: help) { kind, selected in
                VStack(spacing: 3) {
                    Image(systemName: symbol(kind))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? scopeColor : Color.primary.opacity(0.7))
                    Text(title(kind))
                        .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.vertical, 6)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(scopeColor)
                    .frame(width: 7, height: 7)
                Text(model.scopeTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if model.scopeHasOverrides {
                    Button(L("Сбросить")) { model.resetScopeStyle() }
                        .glassButton()
                        .controlSize(.small)
                        .help(L("Вернуть общий стиль для этой области"))
                }
            }
            .frame(minHeight: 20)
            .padding(.horizontal, 4)
        }
    }

    private var currentKind: ScopeKind {
        switch model.scope {
        case .all: return .all
        case .group: return .group
        case .cues: return .cues
        case .words: return .words
        }
    }

    private var scopeColor: Color {
        if case .group(let id) = model.scope, let group = model.group(id) { return group.color.color }
        return model.scope == .all ? Color.primary.opacity(0.55) : Color.accentColor
    }

    private func title(_ kind: ScopeKind) -> String {
        switch kind {
        case .all: return L("Все")
        case .group: return L("Группа")
        case .cues: return model.selectedCueIDs.count > 1 ? L("Выбранные") : L("Субтитр")
        case .words: return L("Слова")
        }
    }

    private func symbol(_ kind: ScopeKind) -> String {
        switch kind {
        case .all: return "rectangle.stack"
        case .group: return "circle.grid.2x2"
        case .cues: return "captions.bubble"
        case .words: return "character.cursor.ibeam"
        }
    }

    private func isEnabled(_ kind: ScopeKind) -> Bool {
        switch kind {
        case .all: return true
        case .group: return model.contextGroupID != nil
        case .cues: return model.hasMedia && !model.scopeCueIDs.isEmpty
        case .words: return model.wordSelection != nil
        }
    }

    private func help(_ kind: ScopeKind) -> String {
        switch kind {
        case .all: return L("Менять общий стиль всех субтитров")
        case .group:
            return model.contextGroupID == nil ? L("Выделите субтитры одной группы или создайте группу (⌘G)") : L("Стиль группы")
        case .cues: return L("Только выбранные субтитры (или тот, что под курсором)")
        case .words: return L("Щёлкните слово на видео, с ⇧ можно выбрать несколько")
        }
    }

    private func select(_ kind: ScopeKind) {
        switch kind {
        case .all: model.scope = .all
        case .group: if let id = model.contextGroupID { model.scope = .group(id) }
        case .cues: model.scope = .cues
        case .words: if model.wordSelection != nil { model.scope = .words }
        }
    }
}

/// Property row with a reset button when the value is changed at the current scope.
private struct StyleRow<Control: View>: View {
    let label: String
    let overridden: Bool
    let onReset: () -> Void
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12.5, weight: overridden ? .semibold : .regular))
                .foregroundStyle(overridden ? Color.accentColor : Color.primary)
                .lineLimit(1)
            if overridden {
                ResetButton(help: L("Вернуть значение из общего стиля"), action: onReset)
            }
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 24)
    }
}

/// Small round "back to the shared value" button next to a changed property.
private struct ResetButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

private extension View {
    /// Row helper bound to an override property.
    func styleRow<T, C: View>(_ model: AppModel, _ label: String, _ key: WritableKeyPath<StyleOverride, T?>,
                              @ViewBuilder control: () -> C) -> some View {
        StyleRow(label: label, overridden: model.isOverridden(key), onReset: { model.resetStyle(key) }, control: control)
    }
}

// MARK: - Text

private struct TextTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let style = model.effectiveStyle
        let isWords = model.scope == .words
        if !isWords {
            InspectorSection(L("Регистр и знаки препинания"), plain: true) {
                CaseModePicker(mode: model.binding(\.caseMode, \.caseMode))
                if model.isOverridden(\.caseMode) {
                    Button(L("Вернуть общий")) { model.resetStyle(\.caseMode) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 4)
                }
            }
        }
        InspectorSection(L("Шрифт")) {
            HStack(spacing: 6) {
                FontFamilyPicker(family: model.binding(\.fontFamily, \.fontFamily), fontsVersion: model.fontsVersion)
                if model.isOverridden(\.fontFamily) {
                    ResetButton(help: L("Вернуть шрифт общего стиля")) {
                        model.resetStyle(\.fontFamily)
                        model.resetStyle(\.fontFace)
                    }
                }
            }
            fontWarnings(style)
            styleRow(model, L("Начертание"), \.fontFace) {
                FacePicker(family: style.fontFamily, face: model.binding(\.fontFace, \.fontFace), fontsVersion: model.fontsVersion)
            }
            WeightControl()
            HStack(spacing: 6) {
                Toggle(isOn: model.italicBinding) {
                    Label(L("Курсив"), systemImage: "italic")
                }
                Toggle(isOn: model.binding(\.uppercase, \.uppercase)) {
                    Label(L("ЗАГЛАВНЫЕ"), systemImage: "textformat.size.larger")
                }
                Spacer(minLength: 0)
            }
            .toggleStyle(ChipToggleStyle())
            Divider()
            SliderProperty(label: L("Наклон"), value: model.binding(\.slant, \.slant), range: -30...30, step: 1, unit: "°")
            SliderProperty(label: L("Размер"), value: model.pixels(\.fontSize, \.fontSize),
                           range: 8...max(400, (model.frameHeight * 0.25).rounded()))
            styleRow(model, L("Цвет текста"), \.textColor) {
                ColorPicker("", selection: colorBinding(model.binding(\.textColor, \.textColor)), supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 44)
            }
            HStack(spacing: 8) {
                Button {
                    model.showFontLibrary = true
                } label: {
                    Label(L("Библиотека шрифтов…"), systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    model.addFonts()
                } label: {
                    Label(L("Файлы…"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help(L("Добавить свои файлы шрифтов (.otf, .ttf)"))
            }
            .glassButton()
            .controlSize(.small)
            .padding(.top, 2)
        }
        InspectorSection(L("Интервалы")) {
            styleRow(model, L("Между буквами"), \.letterSpacing) {
                ValueField(value: model.pixels(\.letterSpacing, \.letterSpacing), range: -40...120)
            }
            if !isWords {
                styleRow(model, L("Между строками"), \.lineGap) {
                    ValueField(value: model.pixels(\.lineGap, \.lineGap), range: -300...300)
                }
            }
        }
        if isWords {
            HighlightSection()
            OutlineSection()
            InspectorSection(L("Слова")) {
                Text(L("Щёлкните слово на видео, ⇧-щелчок добавит ещё. Стиль слов сохраняется при правке текста."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let selection = model.wordSelection, let cue = model.cues.first(where: { $0.id == selection.cueID }) {
                    Button(L("Выделить все слова субтитра")) { model.selectAllWords(of: cue) }
                        .glassButton()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func fontWarnings(_ style: SubtitlePreset) -> some View {
        let _ = model.fontsVersion
        if !FontLibrary.isAvailable(family: style.fontFamily) {
            warning(L("Шрифта «%@» нет на этом Mac, пока вместо него показан похожий.", "\(style.fontFamily)"))
        } else if !FontLibrary.supportsCyrillic(family: style.fontFamily) {
            warning(L("В шрифте нет русских букв, они будут набраны другим шрифтом."))
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

func colorBinding(_ binding: Binding<RGBAColor>) -> Binding<Color> {
    Binding(get: { binding.wrappedValue.color }, set: { binding.wrappedValue = RGBAColor($0) })
}

/// Weight as a slider over the faces the font really has (Thin … Black).
private struct WeightControl: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let style = model.effectiveStyle
        let faces = model.weightFaces(family: style.fontFamily, italic: model.currentFaceIsItalic)
        let target = FontLibrary.weight(forStyleName: style.fontFace)
        let index = faces.firstIndex { $0.styleName == style.fontFace }
            ?? faces.indices.min(by: { abs(faces[$0].weight - target) < abs(faces[$1].weight - target) })
            ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Жирность"))
                    .font(.system(size: 12.5))
                Spacer()
                Text(faces.isEmpty ? "—" : faces[min(index, faces.count - 1)].styleName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if faces.count > 1 {
                Slider(value: Binding(
                    get: { Double(index) },
                    set: { value in
                        let i = min(max(0, Int(value.rounded())), faces.count - 1)
                        if faces[i].styleName != style.fontFace {
                            model.setStyle(\.fontFace, \.fontFace, faces[i].styleName)
                        }
                    }
                ), in: 0...Double(faces.count - 1), step: 1)
                .controlSize(.small)
            } else {
                Text(L("У шрифта одно начертание"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The four case/punctuation variants as selectable cards.
struct CaseModePicker: View {
    @Binding var mode: TextCaseMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(TextCaseMode.allCases) { item in
                let selected = item == mode
                Button {
                    withAnimation(Motion.animation(Motion.quick, reduceMotion: reduceMotion)) { mode = item }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.shortTitle)
                            .font(.system(size: 18, weight: .semibold))
                            .lineLimit(1)
                        Text(caption(item))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(8)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .background {
                        let shape = RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous)
                        shape.fill(Color.card)
                            .overlay(shape.fill(Color.accentColor.opacity(selected ? 0.14 : 0)))
                            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.05),
                                                        lineWidth: selected ? 2 : 1))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help(item.title)
            }
        }
    }

    private func caption(_ item: TextCaseMode) -> String {
        switch item {
        case .original: return L("Заглавные, со знаками")
        case .originalNoPunctuation: return L("Заглавные, без знаков")
        case .lowercase: return L("Строчные, со знаками")
        case .lowercaseNoPunctuation: return L("Строчные, без знаков")
        }
    }
}

// MARK: - Layout

private struct LayoutTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InspectorSection(L("Кадр")) {
            PropertyRow(model.hasVideo ? L("Размер видео") : L("Формат превью")) {
                Text(verbatim: "\(Int(model.frameWidth)) × \(Int(model.frameHeight)) px")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            note(L("Все значения указаны в пикселях этого кадра. Для видео другого размера стиль масштабируется сам."))
        }
        InspectorSection(L("Строки")) {
            SegmentedTrack(selection: model.binding(\.maxLines, \.maxLines), values: [1, 2, 3]) { lines, selected in
                Text(lines == 1 ? L("1 строка") : lines == 2 ? L("2 строки") : L("3 строки"))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(height: 24)
            }
            VStack(alignment: .leading, spacing: 6) {
                styleRow(model, L("Ширина блока"), \.maxWidth) {
                    ValueField(value: model.blockWidthPixels, range: (model.frameWidth * 0.1).rounded()...model.frameWidth)
                }
                Slider(value: model.blockWidthPixels, in: (model.frameWidth * 0.1).rounded()...model.frameWidth)
                    .controlSize(.small)
            }
        }
        InspectorSection(L("Положение")) {
            styleRow(model, L("Привязка"), \.anchor) {
                SymbolSegments(selection: model.anchorKeepingPosition, items: [
                    (.top, "align.vertical.top", L("Y отмечает верхний край текста")),
                    (.center, "align.vertical.center", L("Y отмечает центр текста")),
                    (.bottom, "align.vertical.bottom", L("Y отмечает нижний край текста")),
                ])
            }
            styleRow(model, L("Выравнивание"), \.alignment) {
                SymbolSegments(selection: model.alignmentKeepingPosition, items: [
                    (.left, "text.alignleft", L("X отмечает левый край текста")),
                    (.center, "text.aligncenter", L("X отмечает центр текста")),
                    (.right, "text.alignright", L("X отмечает правый край текста")),
                ])
            }
            styleRow(model, "X", \.positionX) {
                ValueField(value: model.positionXPixels, range: 0...model.frameWidth)
            }
            styleRow(model, "Y", \.positionY) {
                ValueField(value: model.positionYPixels, range: 0...model.frameHeight)
            }
            HStack(spacing: 6) {
                Button(L("Сверху")) { model.place(.top) }
                Button(L("По центру")) { model.place(.center) }
                Button(L("Снизу")) { model.place(.bottom) }
                Spacer(minLength: 0)
                Button {
                    model.centerHorizontally()
                } label: {
                    Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                }
                .help(L("Центрировать по горизонтали"))
            }
            .glassButton()
            .controlSize(.small)
            note(model.scope == .all
                 ? L("Субтитры можно двигать мышью прямо на видео. Чтобы сдвинуть один субтитр, выберите «Субтитр» вверху.")
                 : L("Мышью на видео сдвигается только эта область."))
        }
        if model.scope == .all {
            InspectorSection(L("Нарезка на субтитры")) {
                PropertyRow(L("Слов на экране")) {
                    ValueMenu(value: wordLimitTitle(model.preset.maxWordsPerCue)) {
                        Picker("", selection: $model.preset.maxWordsPerCue) {
                            Text(wordLimitTitle(0)).tag(0)
                            ForEach([1, 2, 3, 4, 5, 6, 7, 8, 10, 12], id: \.self) { count in
                                Text(wordLimitTitle(count)).tag(count)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                PropertyRow(L("Макс. длительность")) {
                    ValueField(value: $model.preset.maxCueDuration, range: 1...15, step: 0.5, unit: L("с"), fractionDigits: 1)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func wordLimitTitle(_ count: Int) -> String {
        count == 0 ? L("Без ограничений") : L("не больше %@", "\(count)")
    }
}

// MARK: - Effects

private struct OutlineSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InspectorSection(L("Обводка"), isOn: model.binding(\.outlineEnabled, \.outlineEnabled)) {
            styleRow(model, L("Цвет"), \.outlineColor) {
                ColorPicker("", selection: colorBinding(model.binding(\.outlineColor, \.outlineColor)), supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 44)
            }
            styleRow(model, L("Толщина"), \.outlineWidth) {
                ValueField(value: model.pixels(\.outlineWidth, \.outlineWidth), range: 1...80)
            }
        }
    }
}

private struct HighlightSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InspectorSection(model.scope == .words ? L("Выделение плашкой") : L("Плашка под каждым словом"), isOn: model.highlightBinding) {
            styleRow(model, L("Цвет плашки"), \.highlightColor) {
                ColorPicker("", selection: colorBinding(model.binding(\.highlightColor, \.highlightColor)), supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 44)
            }
            let current = model.effectiveStyle.highlightColor
            HStack(spacing: 7) {
                ForEach(Self.swatches, id: \.self) { color in
                    Button {
                        model.setStyle(\.highlightColor, \.highlightColor, color)
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.18)))
                            .padding(2.5)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: color == current ? 2 : 0))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    static let swatches: [RGBAColor] = [
        RGBAColor(r: 1, g: 0.84, b: 0.04), RGBAColor(r: 1, g: 0.18, b: 0.33), RGBAColor(r: 0.2, g: 0.78, b: 0.35),
        RGBAColor(r: 0.0, g: 0.48, b: 1.0), RGBAColor(r: 0.69, g: 0.32, b: 0.87), RGBAColor.white, RGBAColor.black,
    ]
}

private struct EffectsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        OutlineSection()
        if model.scope != .words {
            InspectorSection(L("Тень"), isOn: model.binding(\.shadowEnabled, \.shadowEnabled)) {
                styleRow(model, L("Цвет"), \.shadowColor) {
                    ColorPicker("", selection: colorBinding(model.binding(\.shadowColor, \.shadowColor)), supportsOpacity: true)
                        .labelsHidden()
                        .frame(width: 44)
                }
                styleRow(model, L("Размытие"), \.shadowBlur) {
                    ValueField(value: model.pixels(\.shadowBlur, \.shadowBlur), range: 0...200)
                }
                styleRow(model, L("Смещение X"), \.shadowOffsetX) {
                    ValueField(value: model.pixels(\.shadowOffsetX, \.shadowOffsetX), range: -200...200)
                }
                styleRow(model, L("Смещение Y"), \.shadowOffsetY) {
                    ValueField(value: model.pixels(\.shadowOffsetY, \.shadowOffsetY), range: -200...200)
                }
            }
            InspectorSection(L("Подложка")) {
                SegmentedTrack(selection: model.binding(\.boxMode, \.boxMode), values: BoxMode.allCases) { mode, selected in
                    Text(mode.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(height: 24)
                }
                if model.effectiveStyle.boxMode != .none {
                    styleRow(model, L("Цвет"), \.boxColor) {
                        ColorPicker("", selection: colorBinding(model.binding(\.boxColor, \.boxColor)), supportsOpacity: true)
                            .labelsHidden()
                            .frame(width: 44)
                    }
                    styleRow(model, L("Отступы"), \.boxPadding) {
                        ValueField(value: model.pixels(\.boxPadding, \.boxPadding), range: 0...200)
                    }
                    styleRow(model, L("Скругление"), \.boxCornerRadius) {
                        ValueField(value: model.pixels(\.boxCornerRadius, \.boxCornerRadius), range: 0...200)
                    }
                }
            }
        }
        HighlightSection()
    }
}
