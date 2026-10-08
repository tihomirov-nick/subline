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

    @Published private(set) var transcript: Transcript?
    @Published var cues: [Cue] = [] {
        didSet { refreshCurrentCue() }
    }
    @Published private(set) var cuesEdited = false
    @Published private(set) var cuesLayoutKey = ""
    /// Subtitle under the playhead.
    @Published private(set) var currentCueID: UUID?
    @Published private(set) var transcriptFromCache = false
    /// Subtitles that share a style.
    @Published var groups: [SubtitleGroup] = []

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
    /// Shown in an alert, which comes with the failure sound.
    @Published var errorMessage: String? {
        didSet { if errorMessage != nil { SoundEffects.play(.failure) } }
    }
    @Published var exportNotice: ExportNotice?
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
    private var pendingCacheSave: (entry: TranscriptCache.Entry, url: URL)?
    private var rebuildTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var updateWatch: AnyCancellable?

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
        language = defaults.string(forKey: "language") ?? "ru"
        prompt = defaults.string(forKey: "prompt") ?? ""
        autoTranscribe = defaults.object(forKey: "autoTranscribe") as? Bool ?? true
        showInspector = defaults.object(forKey: "showInspector") as? Bool ?? true
        previewAspect = PreviewAspect(rawValue: defaults.string(forKey: "previewAspect") ?? "") ?? .vertical

        modelStore.onInstalled = { [weak self] id in
            guard let self else { return }
            if self.modelStore.modelURL(for: self.modelID) == nil { self.modelID = id }
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

    func restoreBuiltInPresets() {
        let existing = Set(presets.map(\.name))
        let missing = SubtitlePreset.builtIn.filter { !existing.contains($0.name) }
        presets.append(contentsOf: missing)
    }

    func exportPresets(all: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = all ? L("Пресеты Subline.json") : L("Пресет %@.json", "\(preset.name)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PresetStore.export(all ? presets : [preset], to: url)
            SoundEffects.play(.send)
        } catch {
            errorMessage = L("Не удалось сохранить пресет: %@", "\(error.localizedDescription)")
        }
    }

    func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var imported: [SubtitlePreset] = []
        for url in panel.urls {
            do {
                imported += try PresetStore.importPresets(from: url)
            } catch {
                errorMessage = L("Файл «%@» не похож на пресет Subline", "\(url.lastPathComponent)")
            }
        }
        guard !imported.isEmpty else { return }
        for var item in imported {
            item.name = uniquePresetName(item.name)
            presets.append(item)
        }
        selectedPresetID = imported.last!.id
        if let missing = imported.map(\.fontFamily).first(where: { !FontLibrary.isAvailable(family: $0) }) {
            errorMessage = L("В пресете указан шрифт «%@», а на этом Mac его нет. Добавьте файлы шрифта через пункт «Добавить файлы шрифтов…» в меню «Стиль»", "\(missing)")
        } else if errorMessage == nil {
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
        guard panel.runModal() == .OK else { return }
        let families = fontStore.importFiles(panel.urls)
        if let error = fontStore.lastError {
            errorMessage = error
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openMedia(url)
    }

    func openMedia(_ url: URL) {
        guard !isExporting else { return }
        workTask?.cancel()
        frameTask?.cancel()
        player.unload()
        exportNotice = nil
        mediaURL = url
        media = nil
        frameImage = nil
        transcript = nil
        cues = []
        groups = []
        clearSelection()
        cuesEdited = false
        cuesLayoutKey = ""
        currentCueID = nil
        transcriptFromCache = false
        activity = Activity(kind: .opening, title: L("Открываю файл…"), progress: nil)

        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await FFmpeg.probe(url)
                guard self.mediaURL == url else { return }
                self.media = info
                self.player.load(info)
                if info.hasVideo {
                    let time = min(max(0, info.duration * 0.1), 3)
                    self.player.seek(to: time)
                    await self.loadFrame(at: time)
                }
                self.activity = nil
                if let cached = TranscriptCache.load(for: url) {
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
                    return
                }
                guard info.hasAudio else {
                    self.errorMessage = MediaError.noAudio.localizedDescription
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
                    self.errorMessage = error.localizedDescription
                    self.mediaURL = nil
                }
            }
        }
    }

    func closeMedia() {
        guard !isExporting else { return }
        workTask?.cancel()
        frameTask?.cancel()
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
        if id != currentCueID { currentCueID = id }
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

    private func handle(_ command: KeyboardController.Command) -> Bool {
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

    func startTranscription() {
        guard let url = mediaURL, let info = media, !isBusy, !updateInProgress else { return }
        guard info.hasAudio else {
            errorMessage = MediaError.noAudio.localizedDescription
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
        workTask = Task { [weak self] in
            let flag = CancelFlag()
            let job = Task.detached(priority: .userInitiated) { () throws -> (segments: [TranscriptSegment], language: String) in
                let work = AppPaths.makeTempDir("transcribe")
                defer { try? FileManager.default.removeItem(at: work) }
                let samples = try await FFmpeg.extractAudioSamples(from: url, workDir: work, duration: info.duration) { p in
                    Task { @MainActor in self?.updateActivity(progress: p * 0.04) }
                }
                if flag.isCancelled || Task.isCancelled { throw WhisperError.cancelled }
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
                return try WhisperEngine.transcribe(samples: samples, options: options, progress: { p in
                    Task { @MainActor in self?.updateActivity(progress: 0.04 + 0.96 * p) }
                }, isCancelled: { flag.isCancelled })
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
                    self.errorMessage = L("Речь не распознана. Проверьте язык распознавания или попробуйте другую модель")
                } else {
                    SoundEffects.play(.success)
                }
            } catch {
                guard let self else { return }
                if self.activity?.kind == .transcribing {
                    if !Self.isCancellation(error) { self.menuBarIcon.finish(.failure) }
                    self.activity = nil
                }
                if !Self.isCancellation(error) {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelActivity() {
        workTask?.cancel()
        activity = nil
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

    func rebuildCues() {
        guard let transcript else { return }
        if cuesEdited || !groups.isEmpty { registerCuesUndo(L("Пересборка субтитров")) }
        let style = LayoutStyle(preset: preset, canvas: canvasSize)
        groups = []
        clearSelection()
        cues = CueBuilder.build(words: transcript.words, style: style, mediaDuration: media?.duration)
        cuesLayoutKey = preset.layoutKey
        cuesEdited = false
        scheduleCacheSave()
    }

    private func styleChanged() {
        guard transcript != nil, !cuesEdited, preset.layoutKey != cuesLayoutKey else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.cuesEdited, self.preset.layoutKey != self.cuesLayoutKey { self.rebuildCues() }
        }
    }

    func updateCueText(_ id: UUID, _ text: String) {
        guard let index = cues.firstIndex(where: { $0.id == id }), cues[index].text != text else { return }
        cues[index].setText(text)
        if wordSelection?.cueID == id { wordSelection = nil }
        markEdited()
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
        registerCuesUndo(L("Удаление субтитра"))
        cues.removeAll { $0.id == id }
        markEdited()
        SoundEffects.play(.delete)
    }

    func mergeWithNext(_ id: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == id }), index + 1 < cues.count else { return }
        registerCuesUndo(L("Объединение субтитров"))
        let next = cues.remove(at: index + 1)
        let offset = CueText.words(cues[index].text).count
        if let styles = next.wordStyles {
            var merged = cues[index].wordStyles ?? [:]
            for (wordIndex, style) in styles { merged[wordIndex + offset] = style }
            cues[index].wordStyles = merged
        }
        cues[index].text += " " + next.text
        cues[index].end = next.end
        markEdited()
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

    /// Splits the current subtitle at the playhead: words are divided proportionally to the time.
    func splitCurrentCue() {
        guard let cue = currentCue, let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let time = player.currentTime
        guard time > cue.start + 0.1, time < cue.end - 0.1 else { return }
        let words = CueText.words(cue.text)
        guard words.count > 1 else { return }
        let fraction = (time - cue.start) / (cue.end - cue.start)
        let splitAt = min(max(1, Int((Double(words.count) * fraction).rounded())), words.count - 1)
        registerCuesUndo(L("Разделение субтитра"))
        var first: [Int: StyleOverride] = [:]
        var second: [Int: StyleOverride] = [:]
        for (wordIndex, style) in cue.wordStyles ?? [:] {
            if wordIndex < splitAt { first[wordIndex] = style } else { second[wordIndex - splitAt] = style }
        }
        cues[index].text = words[..<splitAt].joined(separator: " ")
        cues[index].wordStyles = first.isEmpty ? nil : first
        cues[index].end = time
        cues.insert(Cue(start: time, end: cue.end, text: words[splitAt...].joined(separator: " "),
                        groupID: cue.groupID, style: cue.style, wordStyles: second.isEmpty ? nil : second), at: index + 1)
        markEdited()
    }

    func markEdited() {
        cuesEdited = true
        scheduleCacheSave()
    }

    func scheduleCacheSave() {
        guard let url = mediaURL, let transcript else { return }
        pendingCacheSave = (TranscriptCache.Entry(transcript: transcript, cues: cues, edited: cuesEdited, layoutKey: cuesLayoutKey,
                                                  modelID: modelID, groups: groups), url)
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, let pending = self.pendingCacheSave else { return }
            self.pendingCacheSave = nil
            await Task.detached(priority: .utility) { TranscriptCache.save(pending.entry, for: pending.url) }.value
        }
    }

    /// Writes changes that are still waiting for the delayed save (before quitting or restarting).
    func flushPendingSaves() {
        if presetSaveTask != nil {
            presetSaveTask?.cancel()
            presetSaveTask = nil
            PresetStore.save(presets)
        }
        cacheSaveTask?.cancel()
        if let pending = pendingCacheSave {
            pendingCacheSave = nil
            TranscriptCache.save(pending.entry, for: pending.url)
        }
    }

    // MARK: - Preview overlay

    private var overlayCache: (key: Int, image: CGImage?)?
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

    /// Subtitle image for the preview, rendered with the export renderer at `pixelWidth`.
    func overlayImage(pixelWidth: CGFloat) -> CGImage? {
        guard let cue = previewCue, pixelWidth > 0 else { return nil }
        let renderer = self.renderer
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(renderer))
        hasher.combine(cue)
        hasher.combine(Int(pixelWidth))
        let key = hasher.finalize()
        if let cache = overlayCache, cache.key == key { return cache.image }
        let image = renderer.makeImage(cue, outputScale: pixelWidth / canvasSize.width)
        overlayCache = (key, image)
        return image
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

    func export(_ format: ExportFormat) {
        guard let info = media, let url = mediaURL, !isBusy, !updateInProgress else { return }
        guard !cues.isEmpty else {
            errorMessage = L("Субтитров пока нет. Сначала распознайте речь")
            return
        }
        if format.needsVideo && !info.hasVideo {
            errorMessage = MediaError.noVideo.localizedDescription
            return
        }
        player.pause()
        let panel = NSSavePanel()
        panel.title = format.title
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + format.fileSuffix + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let output = panel.url else { return }
        export(format, to: output)
    }

    /// Export without the save panel (used by automated checks).
    func exportForTesting(_ format: ExportFormat, to output: URL) {
        export(format, to: output)
    }

    private func export(_ format: ExportFormat, to output: URL) {
        guard let info = media else { return }
        let preset = self.preset
        let cues = self.cues
        let groups = self.groups
        if format == .srt {
            do {
                try Exporter.srt(cues: cues, renderer: renderer).write(to: output, atomically: true, encoding: .utf8)
                showNotice(output)
                SoundEffects.play(.send)
            } catch {
                errorMessage = L("Не удалось сохранить SRT: %@", "\(error.localizedDescription)")
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
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func showNotice(_ url: URL) {
        exportNotice = ExportNotice(url: url)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self?.exportNotice = nil
        }
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
