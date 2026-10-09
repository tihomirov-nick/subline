import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ImageIO
import SublineCore

/// Frame proportions used for the preview before a video is opened.
enum PreviewAspect: String, CaseIterable, Identifiable {
    case vertical, horizontal, square, portrait

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vertical: return "9:16"
        case .horizontal: return "16:9"
        case .square: return "1:1"
        case .portrait: return "4:5"
        }
    }

    var size: CGSize {
        switch self {
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .horizontal: return CGSize(width: 1920, height: 1080)
        case .square: return CGSize(width: 1080, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1350)
        }
    }
}

struct Activity: Equatable {
    enum Kind { case opening, transcribing, exporting }
    var kind: Kind
    var title: String
    var progress: Double?
}

struct ExportNotice: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// A message without an error: why something cannot be done right now.
struct InfoMessage: Equatable {
    let title: String
    let text: String
}

/// A question before an action that loses work: what will happen, the button that does it, and «Отмена».
struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirm: String
    var destructive = true
    let action: () -> Void
}

/// The caret in the text of a subtitle, kept for a moment after typing ends (a click on "Split" ends typing first).
struct TextCaret: Equatable {
    let cueID: UUID
    /// UTF-16 offset, as AppKit counts it.
    let offset: Int
    /// The text the offset belongs to.
    let text: String
    let time: Date
}

/// Thread-safe cancellation flag for code that cannot use Task cancellation (whisper callbacks).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// The subtitle image over the video, drawn off the main thread with the export renderer. Drawing the outline of the
/// text takes milliseconds at screen size; on the main thread it held up every letter typed into the subtitle under the
/// playhead, every step of a style slider and every jump of the playhead. The image shown stays until the next one is
/// drawn (a few milliseconds later); requests made meanwhile are merged, only the latest is drawn next.
@MainActor
final class PreviewOverlay: ObservableObject {
    /// The renderer is held, not just named: a new one may not reuse the address of an old one and pass for it.
    struct Key: Equatable {
        let renderer: CueRenderer
        let cue: Cue
        let pixelWidth: Int

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.renderer === rhs.renderer && lhs.cue == rhs.cue && lhs.pixelWidth == rhs.pixelWidth
        }
    }

    /// The image shown and what it shows (published by hand: see `request`).
    private var current: (key: Key, image: CGImage?)?
    private var wanted: Key?
    private var drawing = false
    private let queue = DispatchQueue(label: "Subline.PreviewOverlay", qos: .userInteractive)

    /// Asks for `cue` drawn `pixelWidth` pixels wide. Called while the canvas draws, so it publishes nothing then: the
    /// very first image is drawn right away and read by the caller; later ones arrive from the queue.
    func request(_ cue: Cue, renderer: CueRenderer, pixelWidth: CGFloat) {
        guard pixelWidth >= 1, renderer.canvas.width > 0 else { return }
        let key = Key(renderer: renderer, cue: cue, pixelWidth: Int(pixelWidth.rounded()))
        guard key != current?.key, key != wanted else { return }
        if current == nil, !drawing {
            current = (key, Self.draw(key))
            return
        }
        wanted = key
        drawNext()
    }

    /// The image when it shows `cue` at any size (a resized window keeps showing it until the sharp one is drawn).
    func image(for cue: Cue) -> CGImage? {
        guard let current, current.key.cue.id == cue.id else { return nil }
        return current.image
    }

    private func drawNext() {
        guard !drawing, let job = wanted else { return }
        wanted = nil
        drawing = true
        queue.async { [weak self] in
            let drawn = Self.draw(job)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.drawing = false
                    self.objectWillChange.send()
                    self.current = (job, drawn)
                    self.drawNext()
                }
            }
        }
    }

    nonisolated private static func draw(_ key: Key) -> CGImage? {
        key.renderer.makeImage(key.cue, outputScale: CGFloat(key.pixelWidth) / key.renderer.canvas.width, forScreen: true)
    }
}

/// The subtitle under the playhead on its own. During playback it changes every couple of seconds, so only the views
/// that show it watch it: the list, the video and the note about a long subtitle, and the inspector when it edits that
/// subtitle. A change of `AppModel` itself redraws much more.
@MainActor
final class PlayheadCue: ObservableObject {
    @Published fileprivate(set) var id: UUID?
}

@MainActor
final class AppModel: ObservableObject {
    let modelStore: ModelStore
    let updater: Updater
    let menuBarIcon: MenuBarIcon
    let fontStore = FontStore()
    let player = PlayerController()
    private let keyboard = KeyboardController()
    private let defaults = UserDefaults.standard

    // MARK: Presets

    @Published var presets: [SubtitlePreset] {
        didSet { presetsChanged(from: oldValue) }
    }
    @Published var selectedPresetID: UUID {
        didSet {
            defaults.set(selectedPresetID.uuidString, forKey: "selectedPreset")
            styleChanged()
            // The video keeps the preset it is styled with.
            if oldValue != selectedPresetID { scheduleCacheSave() }
        }
    }

    // MARK: Recognition settings

    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "modelID") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var prompt: String { didSet { defaults.set(prompt, forKey: "prompt") } }
    @Published var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: "autoTranscribe") } }

    // MARK: Media

    @Published private(set) var mediaURL: URL?
    @Published private(set) var media: MediaInfo?
    /// Still frame shown until the player can display the video (or for files that cannot be played).
    @Published private(set) var frameImage: CGImage?
    @Published var previewAspect: PreviewAspect {
        didSet {
            defaults.set(previewAspect.rawValue, forKey: "previewAspect")
            if media?.hasVideo != true { styleChanged() }
        }
    }

    // MARK: Subtitles

    @Published private(set) var transcript: Transcript? {
        didSet { transcriptRevision += 1 }
    }
    /// Changes with every new transcript: a cut made in the background for an older one is dropped.
    private var transcriptRevision = 0
    @Published var cues: [Cue] = [] {
        didSet { refreshCurrentCue() }
    }
    @Published private(set) var cuesEdited = false
    @Published private(set) var cuesLayoutKey = ""
    /// Subtitle under the playhead: `playheadCue` publishes it.
    let playheadCue = PlayheadCue()
    /// The subtitle image over the video.
    let previewOverlay = PreviewOverlay()
    var currentCueID: UUID? { playheadCue.id }
    @Published private(set) var transcriptFromCache = false
    /// Subtitles that share a style.
    @Published var groups: [SubtitleGroup] = []
    /// The subtitle whose text is being typed in the list.
    @Published var editingCueID: UUID?
    /// Typing should move to the text of this subtitle (Tab).
    @Published var textFocusRequest: UUID?
    var textCaret: TextCaret?
    /// The subtitle whose text changes already have an undo step in this round of typing.
    private var textUndoCueID: UUID?

    // MARK: Editing scope (what the inspector changes)

    @Published var scope: EditScope = .all
    /// Subtitles selected in the list (⌘/⇧-click).
    @Published var selectedCueIDs: Set<UUID> = []
    /// Words selected on the video.
    @Published var wordSelection: WordSelection?
    var selectionAnchorID: UUID?
    var copiedStyle: StyleOverride?

    // MARK: Window state

    @Published private(set) var activity: Activity? {
        didSet { menuBarIcon.show(activity) }
    }
    /// A failure, shown in an alert with the failure sound: what happened, why and what to do. Its technical text
    /// opens under «Подробнее».
    @Published var problem: Problem? {
        didSet { if problem != nil { SoundEffects.play(.failure) } }
    }
    /// The technical text of a problem, in a sheet of its own.
    @Published var problemDetails: String?
    /// The message of the problem on screen.
    var errorMessage: String? { problem?.message }
    /// The result of the last export: it stays over the video until it is closed or another job starts.
    @Published var exportNotice: ExportNotice?
    /// Shown in an alert without the failure sound.
    @Published var infoMessage: InfoMessage?
    /// A question before an action that would lose work.
    @Published var confirmation: Confirmation?
    @Published var showHelp = false
    /// ⌘S: the "Saved" mark lights up for a moment.
    @Published private(set) var savedFlash = 0
    /// Videos opened lately, the newest first (File → Open Recent).
    @Published private(set) var recentFiles: [URL] = []
    /// The file of the last export (File → Show Last Export), kept between launches.
    @Published private(set) var lastExportURL: URL?
    /// The video of the last session came back with its subtitles (the name is shown for a few seconds).
    @Published var restoreNotice: String?
    @Published var showModelManager = false
    @Published var showInspector: Bool { didSet { defaults.set(showInspector, forKey: "showInspector") } }
    @Published var inspectorTab: InspectorTab = .text
    @Published var showFontLibrary = false
    @Published var fontsVersion = 0
    /// An update is being downloaded or installed: Subline restarts soon, so recognition and export wait.
    @Published private(set) var updateInProgress = false

    /// The window's undo manager (set by the main view).
    weak var undoManager: UndoManager?
    var isRestoringUndo = false
    private var lastPresetUndo: Date?
    var lastStyleUndo: Date?
    private var rendererCache: (key: Int, renderer: CueRenderer)?

    private var workTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var pendingFrameTime: Double?
    private var presetSaveTask: Task<Void, Never>?
    private var cacheSaveTask: Task<Void, Never>?
    private var pendingCacheSave: (entry: TranscriptCache.Entry, url: URL, key: String?)?
    /// The content key of the open file's saved work (computed once when it opens).
    private var cacheKey: String?
    private var rebuildTask: Task<Void, Never>?
    /// A long transcript being cut into subtitles in the background.
    private var buildJob: Task<[Cue]?, Never>?
    private var restoreNoticeTask: Task<Void, Never>?
    private var srtTask: Task<Void, Never>?
    private var updateWatch: AnyCancellable?
    private var fitCache: (renderer: CueRenderer, fits: [UUID: (hash: Int, fit: LineFit)])?

    /// The video being worked on and the playhead, for the next launch.
    private enum SessionKey {
        static let media = "lastMediaPath"
        static let time = "lastMediaTime"
        static let recent = "recentMedia"
        static let lastExport = "lastExportPath"
    }

    /// Transcripts with more words are cut into subtitles in the background (about 20 minutes of speech).
    static let backgroundBuildWords = 3000

    init() {
        WhisperEngine.setLoggingEnabled(false)
        FontLibrary.registerAppFonts()
        // The app was already approved by the user; the bundled ffmpeg must not trigger Gatekeeper again.
        if let ffmpeg = AppPaths.ffmpegURL {
            removexattr(ffmpeg.path, "com.apple.quarantine", 0)
        }
        Task.detached(priority: .utility) { WhisperEngine.warmUp() }

        modelStore = ModelStore()
        updater = Updater(repo: "tihomirov-nick/subline")
        menuBarIcon = MenuBarIcon()
        let loaded = PresetStore.load()
        presets = loaded
        let savedPreset = defaults.string(forKey: "selectedPreset").flatMap(UUID.init(uuidString:))
        selectedPresetID = loaded.first(where: { $0.id == savedPreset })?.id ?? loaded[0].id
        modelID = defaults.string(forKey: "modelID") ?? ModelCatalog.recommended.id
        // Until the person picks a language: Russian with the Russian interface, else the language of the Mac or detection.
        language = defaults.string(forKey: "language")
            ?? WhisperEngine.defaultLanguage(interface: Localization.current, preferredLanguages: Locale.preferredLanguages)
        prompt = defaults.string(forKey: "prompt") ?? ""
        autoTranscribe = defaults.object(forKey: "autoTranscribe") as? Bool ?? true
        showInspector = defaults.object(forKey: "showInspector") as? Bool ?? true
        previewAspect = PreviewAspect(rawValue: defaults.string(forKey: "previewAspect") ?? "") ?? .vertical
        recentFiles = (defaults.stringArray(forKey: SessionKey.recent) ?? []).map { URL(fileURLWithPath: $0) }
        lastExportURL = defaults.string(forKey: SessionKey.lastExport).map { URL(fileURLWithPath: $0) }

        modelStore.onInstalled = { [weak self] id in
            guard let self else { return }
            if self.modelStore.modelURL(for: self.modelID) == nil { self.modelID = id }
            Accessibility.announce(L("Модель «%@» готова к работе", self.modelStore.displayName(for: id)))
        }
        ensureValidModelSelection()

        player.onTimeChange = { [weak self] time in
            self?.playheadMoved(to: time)
        }
        fontStore.onChange = { [weak self] in
            self?.fontsVersion += 1
        }
        // The store was created before the app fonts were registered (purchased fonts count as installed).
        fontStore.refresh()
        keyboard.install { [weak self] command in
            self?.handle(command) ?? false
        }
        updateWatch = updater.$state.sink { [weak self] state in
            guard let self else { return }
            // An update that broke off sounds like any failure; finding one is silent.
            if case .failed = state, self.updateInProgress { SoundEffects.play(.failure) }
            switch state {
            case .downloading, .installing: self.updateInProgress = true
            default: self.updateInProgress = false
            }
        }
        updater.start()
    }

    // MARK: - Presets

    var preset: SubtitlePreset {
        get { presets.first { $0.id == selectedPresetID } ?? presets[0] }
        set {
            guard let index = presets.firstIndex(where: { $0.id == newValue.id }) else { return }
            presets[index] = newValue
        }
    }

    private func presetsChanged(from old: [SubtitlePreset]) {
        if let previous = old.first(where: { $0.id == selectedPresetID }), previous != preset,
           presets.contains(where: { $0.id == previous.id }) {
            registerPresetUndo(previous)
        }
        presetSaveTask?.cancel()
        presetSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            PresetStore.save(self.presets)
            self.presetSaveTask = nil
        }
        if old.first(where: { $0.id == selectedPresetID }) != preset {
            styleChanged()
        }
    }

    func addPreset() {
        let copy = preset.duplicated(name: uniquePresetName(L("Новый пресет")))
        presets.append(copy)
        selectedPresetID = copy.id
    }

    func duplicatePreset() {
        let copy = preset.duplicated(name: uniquePresetName(preset.name + L(" копия")))
        presets.append(copy)
        selectedPresetID = copy.id
    }

    func renamePreset(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        preset.name = trimmed
    }

    func deletePreset() {
        guard presets.count > 1, let index = presets.firstIndex(where: { $0.id == selectedPresetID }) else { return }
        presets.remove(at: index)
        selectedPresetID = presets[min(index, presets.count - 1)].id
        SoundEffects.play(.delete)
    }

    /// «Восстановить стандартные пресеты» asks first: the changes made to the built-in presets go.
    func requestRestoreBuiltInPresets() {
        confirmation = Confirmation(
            title: L("Восстановить стандартные пресеты?"),
            message: L("Стандартные пресеты вернутся к исходному виду, их изменения пропадут. Ваши собственные пресеты останутся как есть. Вернуть всё назад можно командой «Отменить» (⌘Z)"),
            confirm: L("Восстановить")
        ) { [weak self] in self?.restoreBuiltInPresets() }
    }

    /// The built-in presets get their original look back, found by identifier; missing ones come back. One undo step.
    func restoreBuiltInPresets() {
        let restored = SubtitlePreset.restoringBuiltIn(in: presets)
        guard restored != presets else { return }
        registerPresetsUndo(presets, name: L("Восстановление пресетов"))
        isRestoringUndo = true
        presets = restored
        isRestoringUndo = false
        lastPresetUndo = nil
    }

    private func registerPresetsUndo(_ previous: [SubtitlePreset], name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setPresetsFromUndo(previous, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func setPresetsFromUndo(_ value: [SubtitlePreset], name: String) {
        registerPresetsUndo(presets, name: name)
        isRestoringUndo = true
        presets = value
        if !presets.contains(where: { $0.id == selectedPresetID }) { selectedPresetID = presets[0].id }
        isRestoringUndo = false
        lastPresetUndo = nil
    }

    func exportPresets(all: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = all ? L("Пресеты Subline.json") : L("Пресет %@.json", "\(preset.name)")
        let chosen = all ? presets : [preset]
        Self.present(panel) { [weak self] panel in
            guard let url = panel.url else { return }
            do {
                try PresetStore.export(chosen, to: url)
                SoundEffects.play(.send)
            } catch {
                self?.problem = .saving(error, output: url)
            }
        }
    }

    func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        Self.present(panel) { [weak self] panel in
            self?.importPresets(from: (panel as? NSOpenPanel)?.urls ?? [])
        }
    }

    private func importPresets(from urls: [URL]) {
        var imported: [SubtitlePreset] = []
        var rejected: [String] = []
        for url in urls {
            do {
                imported += try PresetStore.importPresets(from: url)
            } catch {
                rejected.append(url.lastPathComponent)
            }
        }
        for var item in imported {
            item.name = uniquePresetName(item.name)
            presets.append(item)
        }
        if let last = imported.last { selectedPresetID = last.id }
        if let name = rejected.first {
            problem = Problem(title: L("Пресет не добавился"), message: L("Файл «%@» не похож на пресет Subline", name))
        } else if let missing = imported.map(\.fontFamily).first(where: { !FontLibrary.isAvailable(family: $0) }) {
            problem = Problem(title: L("Шрифта пресета нет на этом Mac"),
                              message: L("В пресете указан шрифт «%@», а на этом Mac его нет. Добавьте файлы шрифта через пункт «Добавить файлы шрифтов…» в меню «Стиль»", "\(missing)"))
        } else if !imported.isEmpty {
            SoundEffects.play(.mark)
        }
    }

    private func uniquePresetName(_ base: String) -> String {
        let names = Set(presets.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Undo

    /// One undo step per adjustment: changes made in quick succession (a slider drag, dragging the text)
    /// are undone together.
    private func registerPresetUndo(_ previous: SubtitlePreset) {
        guard !isRestoringUndo, let undoManager else { return }
        let now = Date()
        defer { lastPresetUndo = now }
        if let last = lastPresetUndo, now.timeIntervalSince(last) < 0.8 { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restorePreset(previous) }
        }
        undoManager.setActionName(L("Изменение стиля"))
    }

    private func restorePreset(_ value: SubtitlePreset) {
        guard let current = presets.first(where: { $0.id == value.id }) else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restorePreset(current) }
        }
        undoManager?.setActionName(L("Изменение стиля"))
        isRestoringUndo = true
        if selectedPresetID != value.id { selectedPresetID = value.id }
        preset = value
        isRestoringUndo = false
        lastPresetUndo = nil
    }

    struct CuesState {
        let cues: [Cue]
        let groups: [SubtitleGroup]
        let edited: Bool
        let layoutKey: String
    }

    func registerCuesUndo(_ name: String) {
        guard !isRestoringUndo, let undoManager else { return }
        let state = CuesState(cues: cues, groups: groups, edited: cuesEdited, layoutKey: cuesLayoutKey)
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreCues(state, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func restoreCues(_ state: CuesState, name: String) {
        let current = CuesState(cues: cues, groups: groups, edited: cuesEdited, layoutKey: cuesLayoutKey)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreCues(current, name: name) }
        }
        undoManager?.setActionName(name)
        isRestoringUndo = true
        groups = state.groups
        cues = state.cues
        cuesEdited = state.edited
        cuesLayoutKey = state.layoutKey
        isRestoringUndo = false
        scheduleCacheSave()
    }

    // MARK: - Fonts

    func addFonts() {
        let panel = NSOpenPanel()
        panel.title = L("Выберите файлы шрифтов")
        panel.allowedContentTypes = [.font, UTType(filenameExtension: "otf"), UTType(filenameExtension: "ttf"), UTType(filenameExtension: "ttc")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        Self.present(panel) { [weak self] panel in
            self?.addFonts((panel as? NSOpenPanel)?.urls ?? [])
        }
    }

    private func addFonts(_ urls: [URL]) {
        let families = fontStore.importFiles(urls)
        if let error = fontStore.lastError {
            problem = Problem(title: L("Шрифт не добавился"), message: error)
            fontStore.lastError = nil
        }
        // A missing font of the current style has just appeared — or use the added family right away.
        if !families.contains(effectiveStyle.fontFamily), let family = families.first {
            setStyle(\.fontFamily, \.fontFamily, family)
        }
    }

    // MARK: - Recognition model

    var selectedModelURL: URL? { modelStore.modelURL(for: modelID) }

    func ensureValidModelSelection() {
        guard modelStore.modelURL(for: modelID) == nil else { return }
        // Prefer the fast multilingual Turbo models, then anything installed.
        let preferred = [ModelCatalog.recommended.id, "large-v3-turbo-q5_0"]
        let available = modelStore.availableModelIDs
        if let id = preferred.first(where: available.contains) ?? available.first {
            modelID = id
        }
    }

    // MARK: - Media

    var hasMedia: Bool { media != nil }
    var hasVideo: Bool { media?.hasVideo == true }
    var isBusy: Bool { activity != nil }
    var isExporting: Bool { activity?.kind == .exporting }

    /// How times are written for the open file: with hours for an hour or longer, everywhere alike.
    var clockFormat: ClockFormat { ClockFormat(duration: media?.duration ?? 0) }

    /// Frame size used for layout: the video size, or the chosen aspect before a video is opened.
    var canvasSize: CGSize {
        if let media, media.hasVideo { return media.size }
        return previewAspect.size
    }

    func showOpenPanel() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.title = L("Выберите видео")
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .audio, .data]
        panel.allowsMultipleSelection = false
        Self.present(panel) { [weak self] panel in
            if let url = panel.url { self?.requestOpen(url) }
        }
    }

    /// Opening a file the person chose (the panel, a drop, Finder, Open Recent). Recognition that runs would stop, so
    /// Subline asks first.
    func requestOpen(_ url: URL) {
        guard activity?.kind == .transcribing, let current = mediaURL else {
            openMedia(url)
            return
        }
        confirmation = Confirmation(
            title: L("Остановить распознавание?"),
            message: L("Сейчас распознаётся «%@». Если открыть «%@», распознавание остановится и его придётся начать заново", current.lastPathComponent, url.lastPathComponent),
            confirm: L("Открыть другой файл")
        ) { [weak self] in self?.openMedia(url) }
    }

    // MARK: - Recent files

    /// The file goes to the top of File → Open Recent.
    private func noteRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = recentFiles.map(\.path).filter { $0 != path }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(10))
        recentFiles = paths.map { URL(fileURLWithPath: $0) }
        defaults.set(paths, forKey: SessionKey.recent)
    }

    func openRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            recentFiles.removeAll { $0 == url }
            defaults.set(recentFiles.map(\.path), forKey: SessionKey.recent)
            infoMessage = InfoMessage(title: L("Файл не найден"),
                                      text: L("Файла «%@» больше нет на прежнем месте. Возможно, его переместили, переименовали или удалили", url.lastPathComponent))
            return
        }
        requestOpen(url)
    }

    func clearRecent() {
        recentFiles = []
        defaults.removeObject(forKey: SessionKey.recent)
    }

    /// Names for Open Recent: files with the same name get their folder.
    func recentTitle(_ url: URL) -> String {
        let name = url.lastPathComponent
        guard recentFiles.filter({ $0.lastPathComponent == name }).count > 1 else { return name }
        return "\(name) (\(url.deletingLastPathComponent().lastPathComponent))"
    }

    /// Opens a video or an audio file. Its subtitles and edits come back from the last time it was open. `restoring`
    /// is the playhead of a session that comes back at launch: then the file opens only to show the saved work.
    func openMedia(_ url: URL, restoring: Double? = nil) {
        guard !isExporting else {
            infoMessage = InfoMessage(title: L("Идёт экспорт"),
                                      text: L("Другое видео можно открыть, когда экспорт закончится или будет остановлен"))
            return
        }
        // The edits of the open video are written before it goes.
        flushPendingCacheSave()
        finishTextEditing()
        workTask?.cancel()
        frameTask?.cancel()
        buildJob?.cancel()
        buildJob = nil
        cacheKey = nil
        player.unload()
        exportNotice = nil
        restoreNotice = nil
        mediaURL = url
        media = nil
        frameImage = nil
        transcript = nil
        cues = []
        groups = []
        clearSelection()
        cuesEdited = false
        cuesLayoutKey = ""
        playheadCue.id = nil
        transcriptFromCache = false
        activity = Activity(kind: .opening, title: L("Открываю файл…"), progress: nil)

        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await FFmpeg.probe(url)
                guard self.mediaURL == url else { return }
                self.media = info
                self.player.load(info)
                // The saved work is found by the content of the file: both ends are read off the main thread.
                let (key, cached) = await Task.detached(priority: .userInitiated) { () -> (String?, TranscriptCache.Entry?) in
                    let key = TranscriptCache.key(for: url)
                    return (key, TranscriptCache.load(key: key, url: url))
                }.value
                guard self.mediaURL == url else { return }
                self.cacheKey = key
                if info.hasVideo || restoring != nil {
                    let start = restoring.map { min(max(0, $0), max(0, info.duration - 0.05)) }
                    let time = start ?? min(max(0, info.duration * 0.1), 3)
                    self.player.seek(to: time)
                    if info.hasVideo { await self.loadFrame(at: time) }
                }
                guard self.mediaURL == url else { return }
                self.activity = nil
                self.rememberSession()
                self.noteRecent(url)
                if let cached {
                    // The preset first: with the cues of another preset the subtitles would be cut again.
                    if let id = cached.presetID, id != self.selectedPresetID, self.presets.contains(where: { $0.id == id }) {
                        self.selectedPresetID = id
                    }
                    self.transcript = cached.transcript
                    self.transcriptFromCache = true
                    if cached.layoutKey == self.preset.layoutKey || cached.edited {
                        self.groups = cached.groups ?? []
                        self.cues = cached.cues
                        self.cuesEdited = cached.edited
                        self.cuesLayoutKey = cached.layoutKey
                    } else {
                        self.rebuildCues()
                    }
                    if restoring != nil { self.showRestoreNotice(url.lastPathComponent) }
                    return
                }
                // A session comes back only to show saved work: nothing starts by itself.
                guard restoring == nil else { return }
                guard info.hasAudio else {
                    self.problem = Problem(title: L("В файле нет звука"), message: MediaError.noAudio.localizedDescription)
                    return
                }
                if self.autoTranscribe {
                    if self.selectedModelURL != nil {
                        self.startTranscription()
                    } else {
                        self.showModelManager = true
                    }
                }
            } catch {
                guard self.mediaURL == url else { return }
                self.activity = nil
                if !Self.isCancellation(error) {
                    self.problem = .opening(error, file: url)
                    self.mediaURL = nil
                }
            }
        }
    }

    func closeMedia() {
        guard !isExporting else { return }
        flushPendingCacheSave()
        finishTextEditing()
        // Closed on purpose: the next launch starts empty. The work stays and comes back with the video.
        forgetSession()
        workTask?.cancel()
        frameTask?.cancel()
        buildJob?.cancel()
        buildJob = nil
        cacheKey = nil
        player.unload()
        mediaURL = nil
        media = nil
        frameImage = nil
        transcript = nil
        cues = []
        groups = []
        clearSelection()
        cuesEdited = false
        activity = nil
        exportNotice = nil
        restoreNotice = nil
    }

    // MARK: - Session

    /// Remembers the open video and the playhead: the next launch opens it again with its subtitles.
    func rememberSession() {
        guard let mediaURL, media != nil else { return }
        defaults.set(mediaURL.path, forKey: SessionKey.media)
        defaults.set(player.currentTime, forKey: SessionKey.time)
    }

    func forgetSession() {
        defaults.removeObject(forKey: SessionKey.media)
        defaults.removeObject(forKey: SessionKey.time)
    }

    /// At launch: the video of the last session opens again where it was left, when it still exists and has saved
    /// subtitles. Nothing is recognized by itself.
    func restoreLastSession() {
        guard mediaURL == nil, let path = defaults.string(forKey: SessionKey.media) else { return }
        let url = URL(fileURLWithPath: path)
        let time = defaults.double(forKey: SessionKey.time)
        // The saved work is looked up by the content of the file, off the main thread (a network disk can be slow).
        Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: path) && TranscriptCache.load(for: url) != nil
            }.value
            guard let self, self.mediaURL == nil else { return }
            guard saved else {
                self.forgetSession()
                return
            }
            self.openMedia(url, restoring: time)
        }
    }

    private func showRestoreNotice(_ name: String) {
        restoreNotice = name
        restoreNoticeTask?.cancel()
        restoreNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.restoreNotice = nil
        }
    }

    // MARK: - Playhead

    private func playheadMoved(to time: Double) {
        refreshCurrentCue()
        if hasVideo && !player.isReady {
            requestFrame(at: time)
        }
    }

    private func refreshCurrentCue() {
        let id = cueIndex(at: player.currentTime).map { cues[$0].id }
        if id != playheadCue.id { playheadCue.id = id }
    }

    /// Binary search over the cues (sorted by start).
    private func cueIndex(at time: Double) -> Int? {
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].end <= time {
                low = mid + 1
            } else if cues[mid].start > time {
                high = mid - 1
            } else {
                return mid
            }
        }
        return nil
    }

    var currentCue: Cue? {
        guard let currentCueID else { return nil }
        return cues.first { $0.id == currentCueID }
    }

    func handle(_ command: KeyboardController.Command) -> Bool {
        guard hasMedia || command == .escape else { return false }
        switch command {
        case .togglePlay: player.togglePlay()
        case .stepFrames(let frames): player.step(frames: frames)
        case .jumpSeconds(let seconds): player.seek(to: player.currentTime + seconds)
        case .previousCue: selectAdjacentCue(-1)
        case .nextCue: selectAdjacentCue(1)
        case .escape:
            guard scope != .all || !selectedCueIDs.isEmpty || wordSelection != nil else { return false }
            clearSelection()
        case .delete:
            guard !deletableCueIDs.isEmpty, !isBusy else { return false }
            deleteCues(deletableCueIDs)
        case .selectAll:
            guard !cues.isEmpty else { return false }
            selectAllCues()
        }
        return true
    }

    /// Moves the playhead to the start of the subtitle: the first video frame on which it is visible
    /// (the same frame where it appears in the exported video). Playback continues when `keepPlaying`.
    func select(_ cue: Cue, keepPlaying: Bool = false) {
        if !keepPlaying { player.pause() }
        var time = cue.start
        if hasVideo, player.frameRate > 0 {
            let firstFrame = (cue.start * player.frameRate - 1e-6).rounded(.up) / player.frameRate
            if firstFrame < cue.end { time = firstFrame }
        }
        player.seek(to: time)
    }

    func selectAdjacentCue(_ offset: Int) {
        guard !cues.isEmpty else { return }
        let time = player.currentTime
        let index: Int
        if let current = cueIndex(at: time) {
            index = current + offset
        } else if offset > 0 {
            index = cues.firstIndex(where: { $0.start > time }) ?? cues.count - 1
        } else {
            index = cues.lastIndex(where: { $0.end <= time }) ?? 0
        }
        select(cues[min(max(0, index), cues.count - 1)], keepPlaying: true)
    }

    // MARK: - Still frames (until the player is ready)

    /// Shows the frame at `time`. Requests made while a frame is being decoded are merged: only the latest
    /// one runs next, so scrubbing never queues up stale frames.
    private func requestFrame(at time: Double) {
        pendingFrameTime = time
        guard frameTask == nil else { return }
        frameTask = Task { [weak self] in
            while let self, let next = self.pendingFrameTime {
                self.pendingFrameTime = nil
                await self.loadFrame(at: next)
            }
            self?.frameTask = nil
        }
    }

    private func loadFrame(at time: Double) async {
        guard let url = mediaURL else { return }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("subline-frame-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            try await FFmpeg.extractFrame(from: url, at: time, maxDimension: 1600, hdrFilter: media?.hdrToSDRFilter, to: output)
        } catch {
            return
        }
        // Decode right away: the temporary file is deleted when this function returns.
        guard mediaURL == url,
              let data = try? Data(contentsOf: output),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
        frameImage = image
    }

    // MARK: - Transcription

    var canTranscribe: Bool { media != nil && !isBusy && !updateInProgress }

    /// «Распознать речь» from the button and the menu: over subtitles edited by hand Subline asks first.
    func requestTranscription() {
        guard canTranscribe else { return }
        guard cuesEdited || !groups.isEmpty else {
            startTranscription()
            return
        }
        confirmation = Confirmation(
            title: L("Распознать речь заново?"),
            message: L("Субтитры правились вручную. После нового распознавания они нарежутся заново, правки и группы пропадут. Вернуть их можно командой «Отменить» (⌘Z)"),
            confirm: L("Распознать заново")
        ) { [weak self] in self?.startTranscription() }
    }

    func startTranscription() {
        guard let url = mediaURL, let info = media, !isBusy, !updateInProgress else { return }
        guard info.hasAudio else {
            problem = Problem(title: L("В файле нет звука"), message: MediaError.noAudio.localizedDescription)
            return
        }
        guard let modelURL = selectedModelURL else {
            showModelManager = true
            return
        }
        workTask?.cancel()
        exportNotice = nil
        activity = Activity(kind: .transcribing, title: L("Извлекаю звук"), progress: 0)
        SoundEffects.play(.start)

        let options = WhisperOptions(modelPath: modelURL.path, language: language, prompt: prompt)
        let modelID = self.modelID
        let language = self.language
        workTask = Task { [weak self] in
            let flag = CancelFlag()
            let job = Task.detached(priority: .userInitiated) { () throws -> (segments: [TranscriptSegment], language: String, silent: Bool) in
                let work = AppPaths.makeTempDir("transcribe")
                defer { try? FileManager.default.removeItem(at: work) }
                let samples = try await FFmpeg.extractAudioSamples(from: url, workDir: work, duration: info.duration) { p in
                    Task { @MainActor in self?.updateActivity(progress: p * 0.04) }
                }
                if flag.isCancelled || Task.isCancelled { throw WhisperError.cancelled }
                // Told apart later when nothing is recognized: silence, or speech the model did not catch.
                let silent = AudioLevel.isSilent(samples)
                if WhisperEngine.isWarmingUp {
                    await MainActor.run {
                        self?.updateActivity(title: L("Готовлю видеокарту (только в первый раз)"), progress: nil)
                    }
                    while WhisperEngine.isWarmingUp && !flag.isCancelled {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                WhisperEngine.warmUp()
                await MainActor.run { self?.updateActivity(title: L("Распознаю речь"), progress: 0.04) }
                let result = try WhisperEngine.transcribe(samples: samples, options: options, progress: { p in
                    Task { @MainActor in self?.updateActivity(progress: 0.04 + 0.96 * p) }
                }, isCancelled: { flag.isCancelled })
                return (result.segments, result.language, silent)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    flag.cancel()
                    job.cancel()
                }
                guard let self, self.mediaURL == url else { return }
                let transcript = Transcript(language: result.language, modelName: self.modelStore.displayName(for: modelID),
                                            duration: info.duration, segments: result.segments)
                self.transcript = transcript
                self.transcriptFromCache = false
                self.rebuildCues()
                self.menuBarIcon.finish(transcript.segments.isEmpty ? .failure : .success)
                self.activity = nil
                if transcript.segments.isEmpty {
                    self.problem = Self.nothingRecognized(silent: result.silent, language: language)
                } else {
                    SoundEffects.play(.success)
                    // A long transcript is still being cut: its count is not known yet.
                    Accessibility.announce(self.isBuildingCues ? L("Распознавание закончено")
                                                               : L("Распознавание закончено. Субтитров: %@", "\(self.cues.count)"))
                }
            } catch {
                guard let self else { return }
                if self.activity?.kind == .transcribing {
                    if !Self.isCancellation(error) { self.menuBarIcon.finish(.failure) }
                    self.activity = nil
                }
                if !Self.isCancellation(error) {
                    self.problem = .recognizing(error, file: url)
                }
            }
        }
    }

    /// Nothing was recognized: the sound is silent, or there is sound the model found no words in (another language,
    /// music, noise).
    static func nothingRecognized(silent: Bool, language: String) -> Problem {
        if silent {
            return Problem(title: L("Речи не слышно"),
                           message: L("Звук в файле очень тихий или его нет совсем, распознавать нечего. Проверьте, тот ли файл открыт"))
        }
        if language == "auto" {
            return Problem(title: L("Речь не распознана"),
                           message: L("Звук есть, но слов модель не нашла. Возможно, в файле музыка или шум без речи. Можно попробовать другую модель"))
        }
        let name = WhisperEngine.languages.first { $0.code == language }?.name ?? language
        return Problem(title: L("Речь не распознана"),
                       message: L("Звук есть, но слов модель не нашла. Сейчас выбран язык «%@», возможно, речь на другом. Выберите язык речи или «Определить автоматически» и распознайте заново", name))
    }

    func cancelActivity() {
        workTask?.cancel()
        activity = nil
    }

    /// Before the window closes or Subline quits: recognition or export would be lost, so Subline asks whether to stop
    /// it. True when closing may go on (nothing runs, or the person chose to stop; the work is then stopped).
    func confirmStopForClosing() -> Bool {
        guard let kind = activity?.kind, kind != .opening else { return true }
        let alert = NSAlert()
        if kind == .exporting {
            alert.messageText = L("Идёт экспорт видео")
            alert.informativeText = L("Если закрыть Subline сейчас, видео не сохранится. Субтитры и правки останутся, экспорт можно будет повторить")
            alert.addButton(withTitle: L("Продолжить экспорт"))
        } else {
            alert.messageText = L("Идёт распознавание речи")
            alert.informativeText = L("Если закрыть Subline сейчас, распознавание прервётся и его придётся начать заново")
            alert.addButton(withTitle: L("Продолжить распознавание"))
        }
        let stop = alert.addButton(withTitle: L("Остановить и закрыть"))
        stop.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        cancelActivity()
        return true
    }

    private func updateActivity(title: String? = nil, progress: Double?) {
        guard var current = activity else { return }
        if let title { current.title = title }
        current.progress = progress
        activity = current
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case MediaError.cancelled = error { return true }
        if case WhisperError.cancelled = error { return true }
        return false
    }

    // MARK: - Subtitles

    /// Subtitles must be rebuilt for the current preset, but the user has edited them.
    var needsRebuild: Bool {
        transcript != nil && cuesEdited && preset.layoutKey != cuesLayoutKey
    }

    /// Cuts the transcript into subtitles by the current preset. A long transcript is cut in the background (a newer
    /// cut cancels it), so sliders of the style stay smooth on an hour of video. `onlyIfUnedited`: the cut follows a
    /// change of the style and is dropped when the subtitles were edited by hand meanwhile.
    func rebuildCues(onlyIfUnedited: Bool = false) {
        guard let transcript else { return }
        buildJob?.cancel()
        buildJob = nil
        let words = transcript.words
        let style = LayoutStyle(preset: preset, canvas: canvasSize)
        let key = preset.layoutKey
        let duration = media?.duration
        guard words.count >= Self.backgroundBuildWords else {
            applyBuiltCues(CueBuilder.build(words: words, style: style, mediaDuration: duration), layoutKey: key)
            return
        }
        let revision = transcriptRevision
        let job = Task.detached(priority: .userInitiated) { () -> [Cue]? in
            let cues = CueBuilder.build(words: words, style: style, mediaDuration: duration, isCancelled: { Task.isCancelled })
            return Task.isCancelled ? nil : cues
        }
        buildJob = job
        Task { [weak self] in
            guard let cues = await job.value, let self, self.buildJob == job else { return }
            self.buildJob = nil
            guard self.transcriptRevision == revision, !(onlyIfUnedited && self.cuesEdited) else { return }
            self.applyBuiltCues(cues, layoutKey: key)
        }
    }

    /// A cut of subtitles is in place: edited subtitles and groups give way (one undo step brings them back).
    private func applyBuiltCues(_ built: [Cue], layoutKey: String) {
        if cuesEdited || !groups.isEmpty { registerCuesUndo(L("Пересборка субтитров")) }
        groups = []
        clearSelection()
        cues = built
        cuesLayoutKey = layoutKey
        cuesEdited = false
        scheduleCacheSave()
    }

    /// Subtitles are being cut in the background.
    var isBuildingCues: Bool { buildJob != nil }

    private func styleChanged() {
        guard transcript != nil, !cuesEdited, preset.layoutKey != cuesLayoutKey else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.cuesEdited, self.preset.layoutKey != self.cuesLayoutKey { self.rebuildCues(onlyIfUnedited: true) }
        }
    }

    /// New text for a subtitle. A one-line style gets no line breaks: they become spaces.
    func updateCueText(_ id: UUID, _ text: String) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let clean = CueText.normalizedInput(text, allowsLineBreaks: allowsLineBreaks(in: cues[index]))
        guard cues[index].text != clean else { return }
        cues[index].setText(clean)
        if wordSelection?.cueID == id { wordSelection = nil }
        markEdited()
    }

    /// The style of the subtitle allows more than one line, so a line break typed by hand can stay.
    func allowsLineBreaks(in cue: Cue) -> Bool {
        renderer.style(for: cue).maxLines > 1
    }

    // MARK: - Typing in the list

    /// Typing starts in the text of a subtitle: the video stops at its start, so it stays on screen.
    func beginTextEditing(_ cue: Cue) {
        editingCueID = cue.id
        textUndoCueID = nil
        select(cue)
    }

    func endTextEditing(_ id: UUID) {
        if editingCueID == id { editingCueID = nil }
        textUndoCueID = nil
    }

    /// Text typed in the list. One undo step per round of typing: ⌘Z after it brings back the text from before.
    func editCueText(_ id: UUID, _ text: String) {
        if textUndoCueID != id {
            registerCuesUndo(L("Правка текста"))
            textUndoCueID = id
        }
        updateCueText(id, text)
    }

    /// Ends typing in the window (the text stays): Space and the arrows go back to the player.
    func finishTextEditing() {
        for window in NSApp.windows where window.firstResponder is NSText && window.attachedSheet == nil {
            window.makeFirstResponder(nil)
        }
    }

    /// The subtitle that commands from the menu and the keyboard act on: the one being typed in, the only selected
    /// one, or the one under the playhead.
    var targetCueID: UUID? {
        if let editingCueID, cues.contains(where: { $0.id == editingCueID }) { return editingCueID }
        if selectedCueIDs.count == 1, let id = selectedCueIDs.first { return id }
        return currentCueID
    }

    func canMoveFirstWordToPrevious(_ id: UUID?) -> Bool {
        guard let id, let index = cues.firstIndex(where: { $0.id == id }) else { return false }
        return index > 0 && !CueText.words(cues[index].text).isEmpty
    }

    func canMoveLastWordToNext(_ id: UUID?) -> Bool {
        guard let id, let index = cues.firstIndex(where: { $0.id == id }) else { return false }
        return index + 1 < cues.count && !CueText.words(cues[index].text).isEmpty
    }

    func canSplit(_ id: UUID?) -> Bool {
        guard let id, let cue = cues.first(where: { $0.id == id }) else { return false }
        return CueText.words(cue.text).count > 1
    }

    /// The first word of the subtitle goes to the end of the previous one.
    func moveFirstWordToPrevious(_ id: UUID) {
        guard canMoveFirstWordToPrevious(id), let index = cues.firstIndex(where: { $0.id == id }) else { return }
        registerCuesUndo(L("Перенос слова"))
        let neighbour = cues[index - 1].id
        var updated = cues
        CueEditor.moveFirstWordToPrevious(&updated, at: index, words: transcript?.words ?? [])
        applyEditedCues(updated, touching: [id, neighbour])
    }

    /// The last word of the subtitle goes to the start of the next one.
    func moveLastWordToNext(_ id: UUID) {
        guard canMoveLastWordToNext(id), let index = cues.firstIndex(where: { $0.id == id }) else { return }
        registerCuesUndo(L("Перенос слова"))
        let neighbour = cues[index + 1].id
        var updated = cues
        CueEditor.moveLastWordToNext(&updated, at: index, words: transcript?.words ?? [])
        applyEditedCues(updated, touching: [id, neighbour])
    }

    /// Splits a subtitle in two: at the text caret when the text is being typed in (or was a moment ago), else at the
    /// playhead when it is inside the subtitle, else where both halves fit the lines of the style best.
    func splitCue(_ id: UUID) {
        guard canSplit(id), let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[index]
        let count = CueText.words(cue.text).count
        let words = transcript?.words ?? []
        var wordIndex: Int?
        var time: Double?
        if let caret = textCaret, caret.cueID == id, caret.text == cue.text,
           editingCueID == id || Date().timeIntervalSince(caret.time) < 3 {
            let k = CueText.wordIndex(atUTF16Offset: caret.offset, in: cue.text)
            if k > 0 && k < count { wordIndex = k }
        }
        let playhead = player.currentTime
        if wordIndex == nil, playhead > cue.start + 0.1, playhead < cue.end - 0.1,
           let k = CueEditor.wordIndex(at: playhead, in: cue, words: words) {
            wordIndex = k
            time = playhead
        }
        guard let k = wordIndex ?? renderer.splitPoint(cue) else { return }
        split(index, beforeWord: k, time: time)
    }

    /// The subtitle does not fit the lines of its style: it becomes two that do.
    func splitToFit(_ id: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == id }), let k = renderer.splitPoint(cues[index]) else { return }
        split(index, beforeWord: k, time: nil)
    }

    private func split(_ index: Int, beforeWord k: Int, time: Double?) {
        registerCuesUndo(L("Разделение субтитра"))
        let id = cues[index].id
        var updated = cues
        guard CueEditor.split(&updated, at: index, beforeWord: k, time: time, words: transcript?.words ?? []) else { return }
        applyEditedCues(updated, touching: [id])
    }

    /// Puts the edited list in place. Word selections of the changed subtitles go (their word numbers moved), and the
    /// text being typed ends when its subtitle is gone.
    private func applyEditedCues(_ updated: [Cue], touching ids: Set<UUID>) {
        if let selection = wordSelection, ids.contains(selection.cueID) {
            wordSelection = nil
            if scope == .words { scope = .cues }
        }
        cues = updated
        selectedCueIDs = selectedCueIDs.filter { id in updated.contains { $0.id == id } }
        if let editingCueID, !updated.contains(where: { $0.id == editingCueID }) { finishTextEditing() }
        markEdited()
    }

    /// How many lines the subtitle takes against the lines of its style (kept until the subtitle or the style changes).
    func lineFit(for cue: Cue) -> LineFit {
        let renderer = self.renderer
        if fitCache?.renderer !== renderer { fitCache = (renderer, [:]) }
        let hash = cue.hashValue
        if let cached = fitCache?.fits[cue.id], cached.hash == hash { return cached.fit }
        let fit = renderer.fit(cue)
        fitCache?.fits[cue.id] = (hash, fit)
        return fit
    }

    func updateCueTiming(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        registerCuesUndo(L("Изменение времени"))
        var cue = cues[index]
        if let start { cue.start = max(0, start) }
        if let end { cue.end = end }
        if cue.end <= cue.start + 0.05 { cue.end = cue.start + 0.5 }
        cues[index] = cue
        cues.sort { $0.start < $1.start }
        markEdited()
    }

    func deleteCue(_ id: UUID) {
        deleteCues([id])
    }

    /// The subtitles ⌫ and «Удалить» remove: the selected ones, else the one commands act on.
    var deletableCueIDs: [UUID] {
        if !selectedCueIDs.isEmpty { return cues.map(\.id).filter(selectedCueIDs.contains) }
        return targetCueID.map { [$0] } ?? []
    }

    /// Removes subtitles in one undo step.
    func deleteCues(_ ids: [UUID]) {
        let removed = Set(ids)
        guard !removed.isEmpty, cues.contains(where: { removed.contains($0.id) }) else { return }
        registerCuesUndo(removed.count > 1 ? L("Удаление субтитров") : L("Удаление субтитра"))
        applyEditedCues(cues.filter { !removed.contains($0.id) }, touching: removed)
        SoundEffects.play(.delete)
    }

    /// Every subtitle selected (⌘A outside the text, «Выбрать все субтитры»).
    func selectAllCues() {
        guard !cues.isEmpty else { return }
        finishTextEditing()
        wordSelection = nil
        selectedCueIDs = Set(cues.map(\.id))
        selectionAnchorID = cues.first?.id
        scope = .cues
    }

    /// Tab in the text of a subtitle: typing goes on in the next one (⇧Tab: the previous one). Past the last subtitle
    /// typing ends.
    func editText(after id: UUID, forward: Bool) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let target = forward ? index + 1 : index - 1
        guard cues.indices.contains(target) else {
            finishTextEditing()
            return
        }
        textFocusRequest = cues[target].id
    }

    func canMergeWithNext(_ id: UUID?) -> Bool {
        guard let id, let index = cues.firstIndex(where: { $0.id == id }) else { return false }
        return index + 1 < cues.count
    }

    func mergeWithNext(_ id: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == id }), index + 1 < cues.count else { return }
        registerCuesUndo(L("Объединение субтитров"))
        let next = cues[index + 1].id
        var updated = cues
        CueEditor.mergeWithNext(&updated, at: index)
        applyEditedCues(updated, touching: [id, next])
    }

    func insertCue(after id: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let start = cues[index].end
        let nextStart = index + 1 < cues.count ? cues[index + 1].start : (media?.duration ?? start + 2)
        let end = max(start + 0.5, min(start + 2, nextStart))
        let cue = Cue(start: start, end: end, text: L("Новый субтитр"))
        registerCuesUndo(L("Новый субтитр"))
        cues.insert(cue, at: index + 1)
        markEdited()
        select(cue)
    }

    /// ⌘B: splits the subtitle being typed in (at the caret) or the one under the playhead (at the playhead).
    func splitCurrentCue() {
        guard let id = targetCueID else { return }
        splitCue(id)
    }

    func markEdited() {
        cuesEdited = true
        scheduleCacheSave()
    }

    /// Subtitles, edits, groups and the preset of the open video are written to disk shortly after every change
    /// (and right away before the video closes or Subline quits), so nothing has to be saved by hand.
    func scheduleCacheSave() {
        guard let url = mediaURL, let transcript else { return }
        pendingCacheSave = (TranscriptCache.Entry(transcript: transcript, cues: cues, edited: cuesEdited, layoutKey: cuesLayoutKey,
                                                  modelID: modelID, groups: groups, presetID: selectedPresetID), url, cacheKey)
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, let pending = self.pendingCacheSave else { return }
            self.pendingCacheSave = nil
            Self.cacheQueue.async { Self.write(pending) }
        }
    }

    private nonisolated static func write(_ pending: (entry: TranscriptCache.Entry, url: URL, key: String?)) {
        if let key = pending.key {
            TranscriptCache.save(pending.entry, key: key, url: pending.url)
        } else {
            TranscriptCache.save(pending.entry, for: pending.url)
        }
    }

    /// ⌘S: the work is written at once (it is written by itself anyway), and the "Saved" mark lights up.
    func saveNow() {
        scheduleCacheSave()
        flushPendingSaves()
        savedFlash += 1
        Accessibility.announce(L("Правки сохранены"))
    }

    /// One writer for the saved subtitles: a newer save never lands before an older one.
    private static let cacheQueue = DispatchQueue(label: "Subline.TranscriptCache", qos: .utility)

    /// Writes changes that are still waiting for the delayed save (before quitting or restarting).
    func flushPendingSaves() {
        if presetSaveTask != nil {
            presetSaveTask?.cancel()
            presetSaveTask = nil
            PresetStore.save(presets)
        }
        flushPendingCacheSave()
        rememberSession()
    }

    /// Writes the subtitles of the open video now if a save is still waiting (after a save already under way).
    func flushPendingCacheSave() {
        cacheSaveTask?.cancel()
        let pending = pendingCacheSave
        pendingCacheSave = nil
        Self.cacheQueue.sync {
            if let pending { Self.write(pending) }
        }
    }

    // MARK: - Preview overlay

    private static let sampleCueID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    /// Renderer for the current preset, groups and frame size (keeps font metrics between frames).
    var renderer: CueRenderer {
        var hasher = Hasher()
        hasher.combine(preset)
        hasher.combine(groups)
        hasher.combine(canvasSize.width)
        hasher.combine(canvasSize.height)
        hasher.combine(fontsVersion)
        let key = hasher.finalize()
        if let cache = rendererCache, cache.key == key { return cache.renderer }
        let renderer = CueRenderer(preset: preset, groups: groups, canvas: canvasSize)
        rendererCache = (key, renderer)
        return renderer
    }

    /// The subtitle shown in the preview: the one under the playhead, or a sample before recognition.
    var previewCue: Cue? {
        if transcript != nil { return currentCue }
        return Cue(id: Self.sampleCueID, start: 0, end: 1, text: sampleCueText)
    }

    var isSampleCue: Bool { previewCue?.id == Self.sampleCueID }

    private var sampleCueText: String {
        let sentence = L("Сегодня покажу, как быстро сделать красивые субтитры для любого видео.")
        let words = sentence.split(separator: " ").enumerated().map { index, word in
            Word(text: String(word), start: Double(index) * 0.35, end: Double(index) * 0.35 + 0.3)
        }
        let style = LayoutStyle(preset: preset, canvas: canvasSize)
        return CueBuilder.build(words: words, style: style).first?.text ?? sentence
    }

    /// Layout of the preview subtitle (word rectangles for selection, block for dragging).
    func previewLayout() -> CueLayout? {
        guard let cue = previewCue else { return nil }
        return renderer.layout(cue)
    }

    /// Text block bounds (video pixels) and the anchor range that keeps it inside the frame.
    func previewBlockGeometry() -> (rect: CGRect, range: (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>))? {
        guard let layout = previewLayout() else { return nil }
        return (layout.blockRect, layout.anchorRange(canvas: canvasSize))
    }

    // MARK: - Export

    /// The format of the Export button: a video for a video, SRT for an audio file.
    var defaultExportFormat: ExportFormat {
        media == nil || hasVideo ? .mp4H264 : .srt
    }

    /// Why the subtitles cannot be exported right now, in words for the person (nil when they can). `format` nil asks
    /// about the Export button.
    func exportBlocker(for format: ExportFormat? = nil) -> String? {
        if updateInProgress {
            return L("Ставится обновление Subline, скоро приложение перезапустится и экспорт снова станет доступен")
        }
        guard mediaURL != nil else { return L("Сначала откройте видео, затем распознайте речь") }
        switch activity?.kind {
        case .opening: return L("Видео ещё открывается")
        case .transcribing: return L("Идёт распознавание речи. Экспорт будет доступен, когда оно закончится")
        case .exporting: return L("Экспорт уже идёт. Его ход виден над видео")
        case nil: break
        }
        guard let media else { return L("Видео ещё открывается") }
        if cues.isEmpty {
            return transcript == nil ? L("Субтитров пока нет. Сначала распознайте речь")
                                     : L("Субтитров нет, экспортировать нечего. Речь можно распознать заново")
        }
        if (format ?? defaultExportFormat).needsVideo && !media.hasVideo {
            return MediaError.noVideo.localizedDescription
        }
        return nil
    }

    func export(_ format: ExportFormat) {
        if let reason = exportBlocker(for: format) {
            infoMessage = InfoMessage(title: L("Экспорт пока недоступен"), text: reason)
            return
        }
        guard let url = mediaURL else { return }
        // Typing ends first: the text in the field is what gets exported.
        finishTextEditing()
        player.pause()
        let panel = NSSavePanel()
        panel.title = format.title
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + format.fileSuffix + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        Self.present(panel) { [weak self] panel in
            guard let self, let output = panel.url else { return }
            if output.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
                self.problem = Problem(title: L("Выберите другое имя"),
                                       message: L("Это файл исходного видео. Сохраните результат под другим именем, иначе исходник пропадёт"))
                return
            }
            self.export(format, to: output)
        }
    }

    /// Export without the save panel (used by automated checks).
    func exportForTesting(_ format: ExportFormat, to output: URL) {
        export(format, to: output)
    }

    /// A recognized transcript without running Whisper (tests): the subtitles are cut from it as after recognition.
    func useTranscriptForTesting(_ transcript: Transcript) {
        self.transcript = transcript
        transcriptFromCache = false
        rebuildCues()
    }

    /// A long job shown in the window without running it (test hooks, for pictures of the interface).
    func stageActivity(_ activity: Activity?) {
        self.activity = activity
    }

    private func export(_ format: ExportFormat, to output: URL) {
        guard let info = media else {
            problem = Problem(title: L("Экспорт не начался"), message: L("Видео закрылось, экспортировать нечего"))
            return
        }
        let preset = self.preset
        let cues = self.cues
        let groups = self.groups
        let source = mediaURL
        if format == .srt {
            // Written in the background: an hour of subtitles takes a noticeable moment to lay out.
            let canvas = canvasSize
            exportNotice = nil
            srtTask?.cancel()
            srtTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { () -> Error? in
                    do {
                        let renderer = CueRenderer(preset: preset, groups: groups, canvas: canvas)
                        try Exporter.srt(cues: cues, renderer: renderer).write(to: output, atomically: true, encoding: .utf8)
                        return nil
                    } catch {
                        return error
                    }
                }.value
                guard let self, !Task.isCancelled else { return }
                self.srtTask = nil
                if let error = result {
                    self.problem = .saving(error, output: output)
                } else {
                    self.showNotice(output)
                    SoundEffects.play(.send)
                }
            }
            return
        }

        workTask?.cancel()
        exportNotice = nil
        activity = Activity(kind: .exporting, title: L("Готовлю субтитры"), progress: 0)
        SoundEffects.play(.start)
        workTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) {
                try await Exporter.exportVideo(info: info, cues: cues, groups: groups, preset: preset, format: format, output: output) { stage, value in
                    Task { @MainActor in self?.updateActivity(title: stage.trimmingCharacters(in: CharacterSet(charactersIn: "…")), progress: value) }
                }
            }
            do {
                try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
                guard let self else { return }
                self.menuBarIcon.finish(.success)
                self.activity = nil
                self.showNotice(output)
                SoundEffects.play(.success)
            } catch {
                guard let self else { return }
                if !Self.isCancellation(error) { self.menuBarIcon.finish(.failure) }
                self.activity = nil
                if !Self.isCancellation(error) {
                    self.problem = .exporting(error, output: output, source: source)
                }
            }
        }
    }

    /// The result stays over the video until it is closed or another job starts; File → Show Last Export finds it later.
    private func showNotice(_ url: URL) {
        exportNotice = ExportNotice(url: url)
        lastExportURL = url
        defaults.set(url.path, forKey: SessionKey.lastExport)
        Accessibility.announce(L("Экспорт готов: %@", url.lastPathComponent))
    }

    /// File → Show Last Export: the file in Finder.
    func revealLastExport() {
        guard let url = lastExportURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            infoMessage = InfoMessage(title: L("Файл не найден"),
                                      text: L("Файла «%@» больше нет на прежнем месте. Возможно, его переместили, переименовали или удалили", url.lastPathComponent))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Panels

    /// Tests: gets the panel instead of the screen.
    static var panelHandlerForTesting: ((NSSavePanel) -> Void)?

    /// Shows an open or save panel as a sheet of the window it belongs to (or of an open sheet); alone when there is
    /// no window yet. `done` runs after OK.
    static func present(_ panel: NSSavePanel, done: @escaping (NSSavePanel) -> Void) {
        if let handler = panelHandlerForTesting {
            handler(panel)
            return
        }
        // A sheet in front (models, fonts) takes the panel; otherwise the main window, even when Settings is in front.
        let key = NSApp.keyWindow
        let main = NSApp.windows.first { $0.identifier?.rawValue == "main" && $0.isVisible }
        if let window = (key?.isSheet == true ? key : nil) ?? main ?? key ?? NSApp.mainWindow,
           window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { done(panel) }
            }
        } else if panel.runModal() == .OK {
            done(panel)
        }
    }
}

/// Spoken by VoiceOver when long work ends (the window may be in the background).
enum Accessibility {
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case text, layout, effects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return L("Текст")
        case .layout: return L("Макет")
        case .effects: return L("Эффекты")
        }
    }
}
