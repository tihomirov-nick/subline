import SwiftUI
import SublineCore

/// The right block: the style of the current scope (all subtitles, a group, subtitles or words). Sizes and positions
/// are in pixels of the current frame. The controls at the top choose what the cards below change.
struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if model.hasMedia && !model.hasVideo {
                    AudioNote()
                }
                PresetBar()
                ScopeBar()
                Segments(selection: $model.inspectorTab,
                         items: InspectorTab.allCases.map { tab in
                             SegmentItem(tab, tab.title, help: tab == .layout && model.scope == .words ? L("У слов нет своего макета") : nil,
                                         enabled: tab != .layout || model.scope != .words)
                         },
                         fill: true, large: true)
            }
            .padding([.horizontal, .top], Metrics.inset)
            .padding(.bottom, 10)
            Separator(leading: 0)
                .padding(.horizontal, Metrics.inset)
            ScrollView {
                ZStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 14) {
                        switch effectiveTab {
                        case .text: TextTab()
                        case .layout: LayoutTab()
                        case .effects: EffectsTab()
                        }
                    }
                    .padding(Metrics.inset)
                    .id(effectiveTab)
                    .transition(.reveal(reduceMotion: reduceMotion))
                }
            }
            .softTopEdge()
            .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: effectiveTab)
        }
    }

    /// Words have no layout of their own.
    private var effectiveTab: InspectorTab {
        model.scope == .words && model.inspectorTab == .layout ? .text : model.inspectorTab
    }
}

/// An audio file is exported only to SRT, and SRT keeps no style: said before the style is set up for nothing.
private struct AudioNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .accessibilityHidden(true)
            Text(L("Это аудио, его можно экспортировать только в SRT. В SRT попадают текст и время, стиль виден лишь в превью"))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preset

private struct PresetBar: View {
    @EnvironmentObject var model: AppModel
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            MenuButton(entries: {
                model.presets.map { preset in
                    .item(preset.name, checked: preset.id == model.selectedPresetID) { model.selectedPresetID = preset.id }
                }
            }) {
                HStack(spacing: 6) {
                    Text(model.preset.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.12)))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .help(L("Пресет хранит общий стиль всех субтитров"))
            .accessibilityLabel(L("Пресет"))
            .accessibilityValue(model.preset.name)
            MenuIconButton(help: L("Действия с пресетом"), size: 30) {
                [
                    .item(L("Новый пресет")) { model.addPreset() },
                    .item(L("Дублировать")) { model.duplicatePreset() },
                    .item(L("Переименовать…")) {
                        newName = model.preset.name
                        isRenaming = true
                    },
                    .separator,
                    .item(L("Экспортировать пресет…")) { model.exportPresets(all: false) },
                    .item(L("Экспортировать все пресеты…")) { model.exportPresets(all: true) },
                    .item(L("Импортировать пресеты…")) { model.importPresets() },
                    .separator,
                    .item(L("Восстановить стандартные пресеты…")) { model.requestRestoreBuiltInPresets() },
                    .item(L("Удалить пресет…"), enabled: model.presets.count > 1) { confirmDelete = true },
                ]
            }
        }
        .confirmationDialog(L("Удалить пресет «%@»?", "\(model.preset.name)"), isPresented: $confirmDelete) {
            Button(L("Удалить"), role: .destructive) { model.deletePreset() }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Это действие нельзя отменить"))
        }
        .alert(L("Название пресета"), isPresented: $isRenaming) {
            TextField(L("Название"), text: $newName)
            Button(L("Сохранить")) { model.renamePreset(to: newName) }
            Button(L("Отмена"), role: .cancel) {}
        }
    }
}

// MARK: - Scope

private enum ScopeKind: Hashable { case all, group, cues, words }

/// Where the changes go: the preset, a group, subtitles or words.
private struct ScopeBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            Segments(selection: Binding(get: { currentKind }, set: { select($0) }),
                     items: [ScopeKind.all, .group, .cues, .words].map { kind in
                         SegmentItem(kind, title(kind), help: help(kind), enabled: isEnabled(kind))
                     },
                     fill: true)
            HStack(spacing: 6) {
                Circle()
                    .fill(scopeColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.scopeTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if model.scopeHasOverrides {
                    Button(L("Сбросить")) { model.resetScopeStyle() }
                        .appButton(.secondary)
                        .controlSize(.mini)
                        .help(L("Вернуть общий стиль для этой области"))
                }
            }
            .frame(height: 20)
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
        return model.scope == .all ? Palette.tertiary : Color.white
    }

    private func title(_ kind: ScopeKind) -> String {
        switch kind {
        case .all: return L("Все")
        case .group: return L("Группа")
        case .cues: return model.selectedCueIDs.count > 1 ? L("Выбранные") : L("Субтитр")
        case .words: return L("Слова")
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
        case .cues: return L("Только выбранные субтитры (или тот, что на текущем кадре)")
        case .words: return L("Щёлкните слово на видео, с ⇧ можно выбрать несколько. Стиль слов сохраняется при правке текста")
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

// MARK: - Building blocks

/// A row bound to a style property: bold with a reset button when the current scope changes it.
@MainActor
private func styleRow<T, C: View>(_ model: AppModel, _ title: String, _ key: WritableKeyPath<StyleOverride, T?>,
                                  help: String? = nil, @ViewBuilder control: () -> C) -> some View {
    Row(title: title, help: help, changed: model.isOverridden(key), onReset: { model.resetStyle(key) }, control: control)
}

/// A color of the style: a click anywhere in the row opens the color panel.
@MainActor
private func colorRow(_ model: AppModel, _ title: String, _ presetKey: WritableKeyPath<SubtitlePreset, RGBAColor>,
                      _ key: WritableKeyPath<StyleOverride, RGBAColor?>) -> some View {
    ColorRow(title: title, changed: model.isOverridden(key), onReset: { model.resetStyle(key) },
             color: colorBinding(model.binding(presetKey, key)))
}

/// A titled group: the name above, the content (usually a card) below.
private struct StyleSection<Content: View>: View {
    let title: String
    var onReset: (() -> Void)?
    @ViewBuilder var content: Content

    init(_ title: String, onReset: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onReset = onReset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title, onReset: onReset)
            content
        }
    }
}

/// A number with a slider under it, for values tried by feel (size, slant, width).
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var unit = "px"
    var changed = false
    var onReset: (() -> Void)?
    var help: String?

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5, weight: changed ? .semibold : .medium))
                    .lineLimit(1)
                if changed, let onReset {
                    ResetButton(action: onReset)
                }
                Spacer(minLength: 6)
                ValueField(value: $value, range: range, step: step, unit: unit)
                    .environment(\.rowTitle, title)
            }
            AppSlider(value: $value, range: range, step: step, label: title,
                      valueText: "\(Int(value.rounded())) \(unit)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .help(help ?? "")
    }
}

// MARK: - Text

private struct TextTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let style = model.effectiveStyle
        let words = model.scope == .words
        if !words {
            StyleSection(L("Регистр и знаки"), onReset: model.isOverridden(\.caseMode) ? { model.resetStyle(\.caseMode) } : nil) {
                Segments(selection: model.binding(\.caseMode, \.caseMode),
                         items: TextCaseMode.allCases.map { SegmentItem($0, $0.shortTitle, help: $0.title) },
                         fill: true, large: true)
            }
        }
        StyleSection(L("Шрифт"), onReset: model.isOverridden(\.fontFamily) ? {
            model.resetStyle(\.fontFamily)
            model.resetStyle(\.fontFace)
        } : nil) {
            VStack(spacing: 0) {
                FontFamilyPicker(family: model.binding(\.fontFamily, \.fontFamily), fontsVersion: model.fontsVersion,
                                 warning: fontWarning(style))
                    .padding(6)
                Separator()
                MenuRow(title: L("Начертание"), changed: model.isOverridden(\.fontFace), onReset: { model.resetStyle(\.fontFace) },
                        value: style.fontFace) {
                    faceNames(style.fontFamily, current: style.fontFace).map { name in
                        .item(name, checked: name == style.fontFace) { model.setStyle(\.fontFace, \.fontFace, name) }
                    }
                }
                Separator()
                WeightRow()
            }
            .card()
        }
        TileGrid {
            Tile(symbol: "italic", title: L("Курсив"), on: model.italicBinding.wrappedValue,
                 help: L("Курсивное начертание шрифта, а если его нет, наклон")) {
                model.italicBinding.wrappedValue.toggle()
            }
            Tile(symbol: "textformat.size.larger", title: L("Заглавные"), on: style.uppercase, help: L("Все буквы заглавные")) {
                model.binding(\.uppercase, \.uppercase).wrappedValue.toggle()
            }
        }
        VStack(spacing: 0) {
            SliderRow(title: L("Размер"), value: model.pixels(\.fontSize, \.fontSize),
                      range: 8...max(400, (model.frameHeight * 0.25).rounded()),
                      changed: model.isOverridden(\.fontSize), onReset: { model.resetStyle(\.fontSize) })
            Separator()
            SliderRow(title: L("Наклон"), value: model.binding(\.slant, \.slant), range: -30...30, unit: "°",
                      changed: model.isOverridden(\.slant), onReset: { model.resetStyle(\.slant) })
            Separator()
            colorRow(model, L("Цвет текста"), \.textColor, \.textColor)
        }
        .card()
        HStack(spacing: 8) {
            Button {
                model.showFontLibrary = true
            } label: {
                Text(L("Библиотека шрифтов"))
                    .frame(maxWidth: .infinity)
            }
            .appButton(.secondary)
            .controlSize(.small)
            .help(L("Открыть библиотеку бесплатных шрифтов с кириллицей (⇧⌘T)"))
            IconButton(symbol: "plus", help: L("Добавить файлы шрифтов (.otf, .ttf)")) {
                model.addFonts()
            }
        }
        StyleSection(L("Интервалы")) {
            VStack(spacing: 0) {
                styleRow(model, L("Между буквами"), \.letterSpacing) {
                    ValueField(value: model.pixels(\.letterSpacing, \.letterSpacing), range: -40...120)
                }
                if !words {
                    Separator()
                    styleRow(model, L("Между строками"), \.lineGap) {
                        ValueField(value: model.pixels(\.lineGap, \.lineGap), range: -300...300)
                    }
                }
            }
            .card()
        }
        if words, let selection = model.wordSelection, let cue = model.cues.first(where: { $0.id == selection.cueID }) {
            Button(L("Выделить все слова субтитра")) {
                model.selectAllWords(of: cue)
            }
            .appButton(.secondary)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
    }

    private func fontWarning(_ style: SubtitlePreset) -> String? {
        _ = model.fontsVersion
        if !FontLibrary.isAvailable(family: style.fontFamily) {
            return L("Шрифта «%@» нет на этом Mac, пока вместо него показан похожий", "\(style.fontFamily)")
        }
        if !FontLibrary.supportsCyrillic(family: style.fontFamily) {
            return L("В шрифте нет русских букв, они будут набраны другим шрифтом")
        }
        return nil
    }

    private func faceNames(_ family: String, current: String) -> [String] {
        var seen = Set<String>()
        var names = FontLibrary.faces(of: family).map(\.styleName).filter { seen.insert($0).inserted }
        if !names.contains(current) { names.append(current) }
        return names
    }
}

/// Weight as a slider over the faces the font really has (Thin … Black).
private struct WeightRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let style = model.effectiveStyle
        let faces = model.weightFaces(family: style.fontFamily, italic: model.currentFaceIsItalic)
        let target = FontLibrary.weight(forStyleName: style.fontFace)
        let index = faces.firstIndex { $0.styleName == style.fontFace }
            ?? faces.indices.min(by: { abs(faces[$0].weight - target) < abs(faces[$1].weight - target) })
            ?? 0
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(L("Жирность"))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(faces.isEmpty ? style.fontFace : faces[min(index, faces.count - 1)].styleName)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: 20)
            if faces.count > 1 {
                AppSlider(value: Binding(
                    get: { Double(index) },
                    set: { value in
                        let i = min(max(0, Int(value.rounded())), faces.count - 1)
                        if faces[i].styleName != style.fontFace {
                            model.setStyle(\.fontFace, \.fontFace, faces[i].styleName)
                        }
                    }
                ), range: 0...Double(faces.count - 1), step: 1, tapsOnSteps: true,
                   label: L("Жирность"), valueText: faces[min(index, faces.count - 1)].styleName)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .help(faces.count > 1 ? "" : L("У шрифта одно начертание"))
    }
}

// MARK: - Layout

private struct LayoutTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StyleSection(L("Кадр")) {
            Row(title: model.hasVideo ? L("Размер видео") : L("Формат превью"),
                help: L("Все значения указаны в пикселях этого кадра. Для видео другого размера стиль масштабируется сам")) {
                Text(verbatim: "\(Int(model.frameWidth)) × \(Int(model.frameHeight)) px")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            .card()
        }
        StyleSection(L("Строки"), onReset: model.isOverridden(\.maxLines) ? { model.resetStyle(\.maxLines) } : nil) {
            Segments(selection: model.binding(\.maxLines, \.maxLines),
                     items: [1, 2, 3].map { SegmentItem($0, $0 == 1 ? L("1 строка") : $0 == 2 ? L("2 строки") : L("3 строки")) },
                     fill: true, large: true)
            SliderRow(title: L("Ширина блока"), value: model.blockWidthPixels,
                      range: (model.frameWidth * 0.1).rounded()...model.frameWidth,
                      changed: model.isOverridden(\.maxWidth), onReset: { model.resetStyle(\.maxWidth) },
                      help: L("Строки переносятся, когда упираются в эту ширину"))
                .card()
        }
        StyleSection(L("Положение")) {
            VStack(spacing: 0) {
                styleRow(model, L("Привязка"), \.anchor) {
                    Segments(selection: model.anchorKeepingPosition, items: [
                        SegmentItem(.top, symbol: "align.vertical.top", help: L("Y отмечает верхний край текста")),
                        SegmentItem(.center, symbol: "align.vertical.center", help: L("Y отмечает центр текста")),
                        SegmentItem(.bottom, symbol: "align.vertical.bottom", help: L("Y отмечает нижний край текста")),
                    ])
                }
                Separator()
                styleRow(model, L("Выравнивание"), \.alignment) {
                    Segments(selection: model.alignmentKeepingPosition, items: [
                        SegmentItem(.left, symbol: "text.alignleft", help: L("X отмечает левый край текста")),
                        SegmentItem(.center, symbol: "text.aligncenter", help: L("X отмечает центр текста")),
                        SegmentItem(.right, symbol: "text.alignright", help: L("X отмечает правый край текста")),
                    ])
                }
                Separator()
                styleRow(model, "X", \.positionX) {
                    ValueField(value: model.positionXPixels, range: 0...model.frameWidth)
                }
                Separator()
                styleRow(model, "Y", \.positionY) {
                    ValueField(value: model.positionYPixels, range: 0...model.frameHeight)
                }
            }
            .card()
            HStack(spacing: 6) {
                Button(L("Сверху")) { model.place(.top) }
                Button(L("По центру")) { model.place(.center) }
                Button(L("Снизу")) { model.place(.bottom) }
                Spacer(minLength: 0)
                IconButton(symbol: "arrow.left.and.line.vertical.and.arrow.right", help: L("Центрировать по горизонтали")) {
                    model.centerHorizontally()
                }
            }
            .appButton(.secondary)
            .controlSize(.small)
            .help(model.scope == .all
                  ? L("Субтитры можно двигать мышью прямо на видео. Чтобы сдвинуть один субтитр, выберите «Субтитр» вверху")
                  : L("Мышью на видео сдвигается только эта область"))
        }
        if model.scope == .all {
            StyleSection(L("Нарезка на субтитры")) {
                VStack(spacing: 0) {
                    MenuRow(title: L("Слов на экране"), value: wordLimitTitle(model.preset.maxWordsPerCue)) {
                        ([0] + [1, 2, 3, 4, 5, 6, 7, 8, 10, 12]).map { count in
                            .item(wordLimitTitle(count), checked: count == model.preset.maxWordsPerCue) {
                                model.preset.maxWordsPerCue = count
                            }
                        }
                    }
                    Separator()
                    Row(title: L("Макс. длительность")) {
                        ValueField(value: $model.preset.maxCueDuration, range: 1...15, step: 0.5, unit: L("с"), fractionDigits: 1)
                    }
                }
                .card()
            }
        }
    }

    private func wordLimitTitle(_ count: Int) -> String {
        count == 0 ? L("Без ограничений") : L("не больше %@", "\(count)")
    }
}

// MARK: - Effects

private struct EffectsTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = model.effectiveStyle
        let words = model.scope == .words
        TileGrid {
            Tile(symbol: "a.square", title: L("Обводка"), on: style.outlineEnabled, help: L("Контур вокруг букв")) {
                toggle(model.binding(\.outlineEnabled, \.outlineEnabled))
            }
            if !words {
                Tile(symbol: "square.filled.on.square", title: L("Тень"), on: style.shadowEnabled, help: L("Тень под текстом")) {
                    toggle(model.binding(\.shadowEnabled, \.shadowEnabled))
                }
            }
            Tile(symbol: "highlighter", title: L("Подсветка"), on: style.highlightEnabled,
                 help: words ? L("Цветной фон под выбранными словами") : L("Цветной фон под каждым словом")) {
                toggle(model.highlightBinding)
            }
        }
        if style.outlineEnabled {
            StyleSection(L("Обводка")) {
                VStack(spacing: 0) {
                    colorRow(model, L("Цвет"), \.outlineColor, \.outlineColor)
                    Separator()
                    styleRow(model, L("Толщина"), \.outlineWidth) {
                        ValueField(value: model.pixels(\.outlineWidth, \.outlineWidth), range: 1...80)
                    }
                }
                .card()
            }
            .transition(.reveal(reduceMotion: reduceMotion))
        }
        if style.shadowEnabled && !words {
            StyleSection(L("Тень")) {
                VStack(spacing: 0) {
                    colorRow(model, L("Цвет"), \.shadowColor, \.shadowColor)
                    Separator()
                    styleRow(model, L("Размытие"), \.shadowBlur) {
                        ValueField(value: model.pixels(\.shadowBlur, \.shadowBlur), range: 0...200)
                    }
                    Separator()
                    styleRow(model, L("Смещение X"), \.shadowOffsetX) {
                        ValueField(value: model.pixels(\.shadowOffsetX, \.shadowOffsetX), range: -200...200)
                    }
                    Separator()
                    styleRow(model, L("Смещение Y"), \.shadowOffsetY) {
                        ValueField(value: model.pixels(\.shadowOffsetY, \.shadowOffsetY), range: -200...200)
                    }
                }
                .card()
            }
            .transition(.reveal(reduceMotion: reduceMotion))
        }
        if style.highlightEnabled {
            HighlightSection()
                .transition(.reveal(reduceMotion: reduceMotion))
        }
        if !words {
            StyleSection(L("Подложка"), onReset: model.isOverridden(\.boxMode) ? { model.resetStyle(\.boxMode) } : nil) {
                Segments(selection: model.binding(\.boxMode, \.boxMode),
                         items: BoxMode.allCases.map { SegmentItem($0, $0.title, help: boxHelp($0)) },
                         fill: true, large: true)
                if style.boxMode != .none {
                    VStack(spacing: 0) {
                        colorRow(model, L("Цвет"), \.boxColor, \.boxColor)
                        Separator()
                        styleRow(model, L("Отступы"), \.boxPadding) {
                            ValueField(value: model.pixels(\.boxPadding, \.boxPadding), range: 0...200)
                        }
                        Separator()
                        styleRow(model, L("Скругление"), \.boxCornerRadius) {
                            ValueField(value: model.pixels(\.boxCornerRadius, \.boxCornerRadius), range: 0...200)
                        }
                    }
                    .card()
                    .transition(.reveal(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private func toggle(_ binding: Binding<Bool>) {
        withAnimation(Motion.animation(Motion.island, reduceMotion: reduceMotion)) {
            binding.wrappedValue.toggle()
        }
    }

    private func boxHelp(_ mode: BoxMode) -> String {
        switch mode {
        case .none: return L("Без подложки")
        case .perLine: return L("Своя подложка под каждой строкой")
        case .block: return L("Одна подложка под всем текстом")
        }
    }
}

private struct HighlightSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let current = model.effectiveStyle.highlightColor
        StyleSection(L("Подсветка слов")) {
            VStack(spacing: 0) {
                colorRow(model, L("Цвет"), \.highlightColor, \.highlightColor)
                Separator()
                HStack(spacing: 0) {
                    ForEach(Self.swatches, id: \.self) { color in
                        Button {
                            model.setStyle(\.highlightColor, \.highlightColor, color)
                            Haptics.tap()
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                                .padding(2.5)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: color == current ? 2 : 0))
                                // The whole column of the swatch takes the click, not only the circle.
                                .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(scale: 0.85))
                        .accessibilityLabel(color.spokenName)
                        .accessibilityAddTraits(color == current ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 6)
                .frame(minHeight: Metrics.rowHeight + 4)
            }
            .card()
        }
    }

    static let swatches: [RGBAColor] = [
        RGBAColor(r: 1, g: 0.84, b: 0.04), RGBAColor(r: 1, g: 0.18, b: 0.33), RGBAColor(r: 0.2, g: 0.78, b: 0.35),
        RGBAColor(r: 0.0, g: 0.48, b: 1.0), RGBAColor(r: 0.69, g: 0.32, b: 0.87), RGBAColor.white, RGBAColor.black,
    ]
}
