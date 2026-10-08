import SwiftUI
import AppKit
import SublineCore

/// Words selected in one subtitle.
struct WordSelection: Equatable {
    var cueID: UUID
    var indices: Set<Int>
}

/// What the inspector changes.
enum EditScope: Equatable {
    /// The preset: every subtitle.
    case all
    /// A group's style.
    case group(UUID)
    /// Selected subtitles (or the one under the playhead when none are selected).
    case cues
    /// Selected words.
    case words
}

/// Style editing on four levels: preset → group → subtitle → word. The inspector reads the effective style
/// of the current scope and writes overrides at that level. Sizes are shown in pixels of the current frame.
extension AppModel {
    // MARK: - Scope

    /// Subtitles changed in the `.cues` scope.
    var scopeCueIDs: [UUID] {
        if !selectedCueIDs.isEmpty { return cues.map(\.id).filter(selectedCueIDs.contains) }
        if let id = currentCueID { return [id] }
        return []
    }

    private var representativeCue: Cue? {
        switch scope {
        case .words:
            guard let selection = wordSelection else { return nil }
            return cues.first { $0.id == selection.cueID }
        case .cues:
            guard let id = scopeCueIDs.first else { return nil }
            return cues.first { $0.id == id }
        case .group(let id):
            return (currentCue?.groupID == id ? currentCue : nil) ?? cues.first { $0.groupID == id }
        case .all:
            return currentCue
        }
    }

    /// Group offered in the scope switcher: the group of the selection or of the subtitle under the playhead.
    var contextGroupID: UUID? {
        if case .group(let id) = scope { return id }
        let ids = scopeCueIDs
        let groupIDs = Set(cues.filter { ids.contains($0.id) }.compactMap(\.groupID))
        if groupIDs.count == 1, cues.filter({ ids.contains($0.id) }).allSatisfy({ $0.groupID != nil }) { return groupIDs.first }
        return nil
    }

    func group(_ id: UUID?) -> SubtitleGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    var scopeTitle: String {
        switch scope {
        case .all:
            return L("Все субтитры (пресет)")
        case .group(let id):
            return L("Группа «%@»", "\(group(id)?.name ?? "")")
        case .cues:
            let count = scopeCueIDs.count
            if count == 0 { return L("Под курсором нет субтитра") }
            return selectedCueIDs.isEmpty ? L("Субтитр под курсором") : L("Выбрано субтитров: %@", "\(count)")
        case .words:
            guard let selection = wordSelection, let cue = cues.first(where: { $0.id == selection.cueID }) else { return L("Слова") }
            let words = CueText.words(cue.text)
            let picked = selection.indices.sorted().compactMap { $0 < words.count ? words[$0] : nil }
            return picked.count == 1 ? L("Слово «%@»", "\(picked[0])") : L("Слова: %@", "\(picked.count)")
        }
    }

    func clearSelection() {
        selectedCueIDs = []
        wordSelection = nil
        selectionAnchorID = nil
        scope = .all
    }

    /// Click on a subtitle row: plain click goes to it, ⌘-click toggles, ⇧-click selects a range.
    func clickRow(_ cue: Cue, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedCueIDs.contains(cue.id) { selectedCueIDs.remove(cue.id) } else { selectedCueIDs.insert(cue.id) }
            selectionAnchorID = cue.id
            wordSelection = nil
            scope = selectedCueIDs.isEmpty ? .all : .cues
        } else if modifiers.contains(.shift),
                  let anchor = selectionAnchorID,
                  let from = cues.firstIndex(where: { $0.id == anchor }),
                  let to = cues.firstIndex(where: { $0.id == cue.id }) {
            selectedCueIDs = Set(cues[min(from, to)...max(from, to)].map(\.id))
            wordSelection = nil
            scope = .cues
        } else {
            selectionAnchorID = cue.id
            if !selectedCueIDs.isEmpty || scope == .words {
                selectedCueIDs = []
                wordSelection = nil
                scope = .cues
            }
        }
        select(cue, keepPlaying: true)
    }

    /// Click on a word on the video. ⇧ adds or removes words.
    func clickWord(_ index: Int, in cue: Cue, extend: Bool) {
        player.pause()
        if extend, var selection = wordSelection, selection.cueID == cue.id {
            if selection.indices.contains(index) { selection.indices.remove(index) } else { selection.indices.insert(index) }
            wordSelection = selection.indices.isEmpty ? nil : selection
        } else {
            wordSelection = WordSelection(cueID: cue.id, indices: [index])
        }
        selectedCueIDs = []
        scope = wordSelection == nil ? .cues : .words
        if inspectorTab == .layout { inspectorTab = .text }
    }

    func selectAllWords(of cue: Cue) {
        let count = CueText.words(cue.text).count
        guard count > 0 else { return }
        wordSelection = WordSelection(cueID: cue.id, indices: Set(0..<count))
        selectedCueIDs = []
        scope = .words
    }

    /// Dragging a subtitle that has its own position edits that subtitle (or its group), not the preset.
    func prepareForPositionDrag() {
        guard let cue = previewCue, !isSampleCue else { return }
        switch scope {
        case .all:
            if cue.style?.positionX != nil || cue.style?.positionY != nil {
                selectedCueIDs = []
                scope = .cues
            } else if let groupID = cue.groupID, let group = group(groupID),
                      group.style.positionX != nil || group.style.positionY != nil {
                scope = .group(groupID)
            }
        case .cues:
            if !scopeCueIDs.contains(cue.id) { selectedCueIDs = [] }
        case .words:
            if wordSelection?.cueID != cue.id {
                wordSelection = nil
                scope = .cues
            }
        case .group(let id):
            if cue.groupID != id { scope = .all }
        }
    }

    // MARK: - Reading and writing styles

    /// The style the inspector shows for the current scope.
    var effectiveStyle: SubtitlePreset {
        switch scope {
        case .all:
            return preset
        case .group(let id):
            return group(id).map { $0.style.applied(to: preset) } ?? preset
        case .cues:
            guard let cue = representativeCue else { return preset }
            return renderer.style(for: cue)
        case .words:
            guard let cue = representativeCue, let index = wordSelection?.indices.min() else { return preset }
            return renderer.style(for: cue, word: index)
        }
    }

    /// Overrides stored at the current scope (nil for the preset).
    var scopeOverride: StyleOverride? {
        switch scope {
        case .all:
            return nil
        case .group(let id):
            return group(id)?.style
        case .cues:
            return representativeCue?.style ?? StyleOverride()
        case .words:
            guard let cue = representativeCue, let index = wordSelection?.indices.min() else { return nil }
            return cue.wordStyles?[index] ?? StyleOverride()
        }
    }

    var scopeHasOverrides: Bool {
        switch scope {
        case .all: return false
        case .group(let id): return !(group(id)?.style.isEmpty ?? true)
        case .cues: return cues.contains { scopeCueIDs.contains($0.id) && !($0.style?.isEmpty ?? true) }
        case .words:
            guard let selection = wordSelection, let cue = cues.first(where: { $0.id == selection.cueID }) else { return false }
            return selection.indices.contains { !(cue.wordStyles?[$0]?.isEmpty ?? true) }
        }
    }

    /// Changes in a burst (a slider drag) become one undo step.
    private func registerStyleUndo() {
        let now = Date()
        defer { lastStyleUndo = now }
        if let last = lastStyleUndo, now.timeIntervalSince(last) < 0.8 { return }
        registerCuesUndo(L("Изменение стиля"))
    }

    /// Applies `change` to the overrides of every target of the scope. False when the scope has no target.
    @discardableResult
    func modifyOverrides(_ change: (inout StyleOverride) -> Void) -> Bool {
        switch scope {
        case .all:
            return false
        case .group(let id):
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
            registerStyleUndo()
            change(&groups[index].style)
        case .cues:
            let ids = Set(scopeCueIDs)
            guard !ids.isEmpty else { return false }
            registerStyleUndo()
            for index in cues.indices where ids.contains(cues[index].id) {
                var style = cues[index].style ?? StyleOverride()
                change(&style)
                cues[index].style = style.isEmpty ? nil : style
            }
        case .words:
            guard let selection = wordSelection, let index = cues.firstIndex(where: { $0.id == selection.cueID }) else { return false }
            registerStyleUndo()
            var styles = cues[index].wordStyles ?? [:]
            for word in selection.indices {
                var style = styles[word] ?? StyleOverride()
                change(&style)
                styles[word] = style.isEmpty ? nil : style
            }
            cues[index].wordStyles = styles.isEmpty ? nil : styles
        }
        markEdited()
        return true
    }

    func setStyle<T>(_ presetKey: WritableKeyPath<SubtitlePreset, T>, _ overrideKey: WritableKeyPath<StyleOverride, T?>, _ value: T) {
        if scope == .all {
            var updated = preset
            updated[keyPath: presetKey] = value
            preset = updated
        } else {
            modifyOverrides { $0[keyPath: overrideKey] = value }
        }
    }

    func binding<T>(_ presetKey: WritableKeyPath<SubtitlePreset, T>, _ overrideKey: WritableKeyPath<StyleOverride, T?>) -> Binding<T> {
        Binding(
            get: { self.effectiveStyle[keyPath: presetKey] },
            set: { self.setStyle(presetKey, overrideKey, $0) }
        )
    }

    /// A size in pixels of the current frame (presets store sizes for a 1080 px short side).
    func pixels(_ presetKey: WritableKeyPath<SubtitlePreset, Double>, _ overrideKey: WritableKeyPath<StyleOverride, Double?>) -> Binding<Double> {
        Binding(
            get: { (self.effectiveStyle[keyPath: presetKey] * self.pixelScale).rounded() },
            set: { self.setStyle(presetKey, overrideKey, $0 / max(self.pixelScale, 0.0001)) }
        )
    }

    func isOverridden<T>(_ overrideKey: KeyPath<StyleOverride, T?>) -> Bool {
        guard scope != .all, let override = scopeOverride else { return false }
        return override[keyPath: overrideKey] != nil
    }

    /// Back to the inherited value.
    func resetStyle<T>(_ overrideKey: WritableKeyPath<StyleOverride, T?>) {
        modifyOverrides { $0[keyPath: overrideKey] = nil }
    }

    func resetScopeStyle() {
        modifyOverrides { $0 = StyleOverride() }
    }

    // MARK: - Copy / paste style

    func copyStyle() {
        switch scope {
        case .all: copiedStyle = StyleOverride.capturing(preset)
        default: copiedStyle = StyleOverride.capturing(effectiveStyle)
        }
        SoundEffects.play(.mark)
    }

    func pasteStyle() {
        guard let copied = copiedStyle else { return }
        let pasted: Bool
        switch scope {
        case .all:
            var updated = copied.applied(to: preset)
            updated.id = preset.id
            updated.name = preset.name
            preset = updated
            pasted = true
        case .words:
            pasted = modifyOverrides { $0 = $0.merging(copied.wordLevel) }
        default:
            pasted = modifyOverrides { $0 = $0.merging(copied) }
        }
        if pasted { SoundEffects.play(.mark) }
    }

    // MARK: - Groups

    func createGroup() {
        let ids = scope == .words ? (wordSelection.map { [$0.cueID] } ?? []) : scopeCueIDs
        guard !ids.isEmpty else { return }
        registerCuesUndo(L("Новая группа"))
        let group = SubtitleGroup(name: L("Группа %@", "\(groups.count + 1)"), color: SubtitleGroup.palette[groups.count % SubtitleGroup.palette.count])
        groups.append(group)
        for index in cues.indices where ids.contains(cues[index].id) {
            cues[index].groupID = group.id
        }
        wordSelection = nil
        scope = .group(group.id)
        markEdited()
    }

    func addToGroup(_ groupID: UUID) {
        let ids = Set(scope == .words ? (wordSelection.map { [$0.cueID] } ?? []) : scopeCueIDs)
        guard !ids.isEmpty else { return }
        registerCuesUndo(L("Добавление в группу"))
        for index in cues.indices where ids.contains(cues[index].id) {
            cues[index].groupID = groupID
        }
        markEdited()
    }

    func removeFromGroup(_ ids: [UUID]) {
        registerCuesUndo(L("Удаление из группы"))
        for index in cues.indices where ids.contains(cues[index].id) {
            cues[index].groupID = nil
        }
        markEdited()
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        registerCuesUndo(L("Переименование группы"))
        groups[index].name = trimmed
        markEdited()
    }

    func recolorGroup(_ id: UUID, _ color: RGBAColor) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].color = color
        markEdited()
    }

    /// Removes the group; its subtitles keep their own styles and go back to the preset look.
    func deleteGroup(_ id: UUID) {
        registerCuesUndo(L("Удаление группы"))
        for index in cues.indices where cues[index].groupID == id {
            cues[index].groupID = nil
        }
        groups.removeAll { $0.id == id }
        if scope == .group(id) { scope = .all }
        markEdited()
        SoundEffects.play(.delete)
    }

    /// Selects the group's subtitles and edits the group style.
    func selectGroup(_ id: UUID) {
        selectedCueIDs = Set(cues.filter { $0.groupID == id }.map(\.id))
        wordSelection = nil
        scope = .group(id)
        if let first = cues.first(where: { $0.groupID == id }), currentCue?.groupID != id {
            select(first)
        }
    }

    func cueCount(inGroup id: UUID) -> Int {
        cues.reduce(0) { $0 + ($1.groupID == id ? 1 : 0) }
    }

    // MARK: - Pixels and position

    /// Video pixels per preset pixel.
    var pixelScale: Double {
        Double(min(canvasSize.width, canvasSize.height)) / SubtitlePreset.referenceShortSide
    }

    var frameWidth: Double { Double(canvasSize.width) }
    var frameHeight: Double { Double(canvasSize.height) }

    /// Writes the position at the current scope (for words: their subtitle).
    func setPosition(x: Double, y: Double) {
        switch scope {
        case .all:
            var updated = preset
            updated.positionX = x
            updated.positionY = y
            preset = updated
        case .words:
            guard let id = wordSelection?.cueID, let index = cues.firstIndex(where: { $0.id == id }) else { return }
            registerStyleUndo()
            var style = cues[index].style ?? StyleOverride()
            style.positionX = x
            style.positionY = y
            cues[index].style = style
            markEdited()
        default:
            modifyOverrides {
                $0.positionX = x
                $0.positionY = y
            }
        }
    }

    var positionXPixels: Binding<Double> {
        Binding(
            get: { (self.effectiveStyle.positionX * self.frameWidth).rounded() },
            set: { self.setPosition(x: $0 / max(self.frameWidth, 1), y: self.effectiveStyle.positionY) }
        )
    }

    var positionYPixels: Binding<Double> {
        Binding(
            get: { (self.effectiveStyle.positionY * self.frameHeight).rounded() },
            set: { self.setPosition(x: self.effectiveStyle.positionX, y: $0 / max(self.frameHeight, 1)) }
        )
    }

    var blockWidthPixels: Binding<Double> {
        Binding(
            get: { (self.effectiveStyle.maxWidth * self.frameWidth).rounded() },
            set: { self.setStyle(\.maxWidth, \.maxWidth, min(1, max(0.1, $0 / max(self.frameWidth, 1)))) }
        )
    }

    /// Block bounds of the subtitle edited in the current scope.
    private var scopeBlockRect: CGRect? {
        guard let cue = representativeCue ?? previewCue else { return nil }
        return renderer.layout(cue)?.blockRect
    }

    /// Changing the alignment keeps the text where it is: the anchor moves to the new reference edge.
    var alignmentKeepingPosition: Binding<TextAlignmentMode> {
        Binding(
            get: { self.effectiveStyle.alignment },
            set: { newValue in
                let rect = self.scopeBlockRect
                self.setStyle(\.alignment, \.alignment, newValue)
                if let rect {
                    let x: CGFloat
                    switch newValue {
                    case .left: x = rect.minX
                    case .center: x = rect.midX
                    case .right: x = rect.maxX
                    }
                    self.setPosition(x: Double(x) / max(self.frameWidth, 1), y: self.effectiveStyle.positionY)
                }
            }
        )
    }

    /// Changing the anchor keeps the text where it is: Y moves to the new reference edge.
    var anchorKeepingPosition: Binding<VerticalAnchor> {
        Binding(
            get: { self.effectiveStyle.anchor },
            set: { newValue in
                let rect = self.scopeBlockRect
                self.setStyle(\.anchor, \.anchor, newValue)
                if let rect {
                    let y: CGFloat
                    switch newValue {
                    case .top: y = rect.minY
                    case .center: y = rect.midY
                    case .bottom: y = rect.maxY
                    }
                    self.setPosition(x: self.effectiveStyle.positionX, y: Double(y) / max(self.frameHeight, 1))
                }
            }
        )
    }

    enum Placement { case top, center, bottom }

    /// Typical placements with safe margins for platform interfaces.
    func place(_ placement: Placement) {
        let anchor: VerticalAnchor
        let y: Double
        switch placement {
        case .top: (anchor, y) = (.top, 0.12)
        case .center: (anchor, y) = (.center, 0.5)
        case .bottom: (anchor, y) = (.bottom, 0.88)
        }
        let x: Double
        switch effectiveStyle.alignment {
        case .left: x = 0.08
        case .center: x = 0.5
        case .right: x = 0.92
        }
        setStyle(\.anchor, \.anchor, anchor)
        setPosition(x: x, y: y)
    }

    func centerHorizontally() {
        setStyle(\.alignment, \.alignment, .center)
        setPosition(x: 0.5, y: effectiveStyle.positionY)
    }

    // MARK: - Typography helpers

    /// Upright (or italic) faces of the family, sorted by weight.
    func weightFaces(family: String, italic: Bool) -> [FontFaceInfo] {
        let faces = FontLibrary.faces(of: family)
        let sameSlant = faces.filter { $0.isItalic == italic }
        var seen = Set<String>()
        return (sameSlant.isEmpty ? faces : sameSlant).filter { seen.insert($0.styleName).inserted }
    }

    var currentFaceIsItalic: Bool {
        let style = effectiveStyle
        return FontLibrary.faces(of: style.fontFamily).first { $0.styleName == style.fontFace }?.isItalic
            ?? style.fontFace.lowercased().contains("italic")
    }

    /// Italic face of the same weight when the font has one, otherwise a synthetic slant.
    var italicBinding: Binding<Bool> {
        Binding(
            get: { self.currentFaceIsItalic || self.effectiveStyle.slant != 0 },
            set: { on in
                let style = self.effectiveStyle
                let faces = FontLibrary.faces(of: style.fontFamily)
                let current = faces.first { $0.styleName == style.fontFace }
                let weight = current?.weight ?? FontLibrary.weight(forStyleName: style.fontFace)
                if on {
                    if let italic = faces.filter(\.isItalic).min(by: { abs($0.weight - weight) < abs($1.weight - weight) }) {
                        self.setStyle(\.fontFace, \.fontFace, italic.styleName)
                    } else {
                        self.setStyle(\.slant, \.slant, 12)
                    }
                } else {
                    if current?.isItalic == true,
                       let upright = faces.filter({ !$0.isItalic }).min(by: { abs($0.weight - weight) < abs($1.weight - weight) }) {
                        self.setStyle(\.fontFace, \.fontFace, upright.styleName)
                    }
                    if style.slant != 0 { self.setStyle(\.slant, \.slant, 0) }
                }
            }
        )
    }

    /// Word highlight: turning it on also removes the outline (a dark outline on a bright plate looks muddy).
    var highlightBinding: Binding<Bool> {
        Binding(
            get: { self.effectiveStyle.highlightEnabled },
            set: { on in
                self.setStyle(\.highlightEnabled, \.highlightEnabled, on)
                if on { self.setStyle(\.outlineEnabled, \.outlineEnabled, false) }
            }
        )
    }
}

extension AppModel {
    /// Clears the word styles of one subtitle.
    func modifyWordStylesReset(_ cueID: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == cueID }), cues[index].wordStyles != nil else { return }
        registerCuesUndo(L("Сброс стиля"))
        cues[index].wordStyles = nil
        markEdited()
    }
}
