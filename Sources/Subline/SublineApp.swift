import SwiftUI
import AppKit
import AVFoundation
import SublineCore

@main
struct SublineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Made on first use, after `init` has carried over the settings. The app delegate wires it up at launch, with or
    // without the window.
    @StateObject private var model = AppModel.shared

    init() {
        FormerName.adoptSettings()
        Localization.apply()
    }

    var body: some Scene {
        Window("Subline", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(model.modelStore)
                .environmentObject(model.fontStore)
                .environmentObject(model.updater)
                .frame(minWidth: 1100, minHeight: 680)
                .modifier(DebugActiveState())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("Проверить обновления…")) { model.updater.check(userInitiated: true) }
            }
            CommandGroup(replacing: .appTermination) {
                Button(L("Завершить Subline")) { AppDelegate.quit(model) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Открыть видео…")) { model.showOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isExporting)
                Menu(L("Открыть недавние")) {
                    ForEach(model.recentFiles, id: \.self) { url in
                        Button(model.recentTitle(url)) { model.openRecent(url) }
                    }
                    Divider()
                    Button(L("Очистить меню")) { model.clearRecent() }
                }
                .disabled(model.recentFiles.isEmpty || model.isExporting)
            }
            CommandGroup(after: .newItem) {
                // The work is saved by itself; ⌘S writes it at once and says so.
                Button(L("Сохранить правки")) { model.saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.transcript == nil)
                Divider()
                // Always available: when export cannot run, Subline says why.
                Button(model.hasMedia && !model.hasVideo ? L("Экспортировать субтитры…") : L("Экспортировать видео с субтитрами…")) {
                    model.export(model.defaultExportFormat)
                }
                .keyboardShortcut("e", modifiers: .command)
                Menu(L("Экспорт в формате")) {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title) { model.export(format) }
                    }
                }
                Button(L("Показать последний экспорт в Finder")) { model.revealLastExport() }
                    .disabled(model.lastExportURL == nil)
                Divider()
                Button(L("Закрыть видео")) { model.closeMedia() }
                    .disabled(model.mediaURL == nil || model.isBusy)
            }
            // ⌘W goes through the same question as the red button while recognition or export runs.
            CommandGroup(replacing: .saveItem) {
                Button(L("Закрыть окно")) { WindowCloseGuard.shared.closeKeyWindow() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? L("Скрыть стиль") : L("Показать стиль")) {
                    withAnimation(Motion.island) { model.showInspector.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            PlayheadCommands(model: model, player: model.player, playheadCue: model.playheadCue)
            CommandGroup(replacing: .help) {
                Button(L("Справка Subline")) { model.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model.updater)
        }
        .windowResizability(.contentSize)
    }
}

/// The menus whose items follow the playhead: the subtitle commands act on the subtitle under it when nothing is
/// selected, and Play turns into Pause. They watch the player and the subtitle under the playhead themselves, since
/// `AppModel` does not publish those (they change too often for everything that watches it).
struct PlayheadCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerController
    @ObservedObject var playheadCue: PlayheadCue

    var body: some Commands {
        // Space, the arrows and ⌫ are shortcuts of these items, but the keys are handled by KeyboardController: in
        // the player it runs the command, in text and on focused controls the key goes to them.
        CommandMenu(L("Воспроизведение")) {
            Button(model.player.isPlaying ? L("Пауза") : L("Воспроизвести")) { model.player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.player.isReady)
            Divider()
            Button(L("Кадр вперёд")) { model.player.step(frames: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.hasMedia)
            Button(L("Кадр назад")) { model.player.step(frames: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.hasMedia)
            Button(L("Секунда вперёд")) { model.player.seek(to: model.player.currentTime + 1) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(!model.hasMedia)
            Button(L("Секунда назад")) { model.player.seek(to: model.player.currentTime - 1) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(!model.hasMedia)
            Divider()
            Button(L("Следующий субтитр")) { model.selectAdjacentCue(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(model.cues.isEmpty)
            Button(L("Предыдущий субтитр")) { model.selectAdjacentCue(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(model.cues.isEmpty)
        }
        CommandMenu(L("Стиль")) {
            Button(L("Скопировать стиль")) { model.copyStyle() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button(L("Вставить стиль")) { model.pasteStyle() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model.copiedStyle == nil)
            Button(L("Сбросить стиль области")) { model.resetScopeStyle() }
                .disabled(!model.scopeHasOverrides)
            Divider()
            Button(L("Сгруппировать выбранные субтитры")) { model.createGroup() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.scopeCueIDs.isEmpty)
            Button(L("Применять ко всем субтитрам")) { model.clearSelection() }
                .disabled(model.scope == .all)
            Divider()
            Button(L("Библиотека шрифтов…")) { model.showFontLibrary = true }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(L("Добавить файлы шрифтов…")) { model.addFonts() }
        }
        CommandMenu(L("Субтитры")) {
            Button(L("Распознать речь")) { model.requestTranscription() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canTranscribe)
            Menu(L("Язык речи")) {
                ForEach(WhisperEngine.languages, id: \.code) { language in
                    Toggle(language.name, isOn: Binding(get: { model.language == language.code },
                                                        set: { if $0 { model.language = language.code } }))
                }
            }
            Button(L("Пересобрать по пресету")) { model.rebuildCues() }
                .disabled(model.transcript == nil || model.isBusy)
            Divider()
            // The subtitle being typed in, the selected one or the one under the playhead.
            Button(L("Разделить субтитр")) { model.splitCurrentCue() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!model.canSplit(model.targetCueID))
            Button(L("Объединить со следующим")) {
                if let id = model.targetCueID { model.mergeWithNext(id) }
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(!model.canMergeWithNext(model.targetCueID))
            Button(L("Перенести первое слово в предыдущий субтитр")) {
                if let id = model.targetCueID { model.moveFirstWordToPrevious(id) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!model.canMoveFirstWordToPrevious(model.targetCueID))
            Button(L("Перенести последнее слово в следующий субтитр")) {
                if let id = model.targetCueID { model.moveLastWordToNext(id) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!model.canMoveLastWordToNext(model.targetCueID))
            Button(L("Добавить субтитр после")) {
                if let id = model.targetCueID { model.insertCue(after: id) }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(model.targetCueID == nil)
            Divider()
            Button(L("Выбрать все субтитры")) { model.selectAllCues() }
                .disabled(model.cues.isEmpty)
            Button(model.deletableCueIDs.count > 1 ? L("Удалить выбранные субтитры") : L("Удалить субтитр")) {
                model.deleteCues(model.deletableCueIDs)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(model.deletableCueIDs.isEmpty || model.isBusy)
            Divider()
            Button(L("Модели распознавания…")) { model.showModelManager = true }
        }
    }
}

extension AppModel {
    /// The window's model, made once. The app delegate wires it up at launch, with or without the window; tests make
    /// models of their own.
    static let shared = AppModel()
}

/// The main window and the Dock icon. Started at login, or brought back quietly by an update that installed itself while
/// Subline ran without them, Subline runs with neither: it only checks for updates and installs them. Opening Subline
/// from the Dock, Launchpad or Finder, a file opened with it and a click on the menu bar icon bring both back.
@MainActor
enum MainWindow {
    /// Running without the window and the Dock icon.
    private(set) static var inBackground = false
    /// Runs when the window comes back from the background (the app delegate brings back the last video).
    static var cameBack: (() -> Void)?

    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }
            ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main-") == true }
    }

    /// While the app launches, before its windows open.
    static func startInBackground() {
        inBackground = true
        NSApp.setActivationPolicy(.accessory)
    }

    /// SwiftUI opens the main window by itself, before applicationDidFinishLaunching: in the background it goes away
    /// there, before it is drawn. A window that opens later goes away in `WindowConfigurator`.
    static func hideWindows() {
        guard inBackground else { return }
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.orderOut(nil)
        }
    }

    /// The window in front, with the Dock icon and the menu bar.
    static func show() {
        if inBackground {
            inBackground = false
            NSApp.setActivationPolicy(.regular)
            cameBack?()
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var attached = false
    private var pendingURLs: [URL] = []
    private var observers: [NSObjectProtocol] = []
    /// The quit waits until then: "Обновляюсь до версии…" stays in the window for a moment before an update that
    /// installed itself restarts Subline.
    private var restartNoticeEnd: Date?

    private var model: AppModel? { attached ? AppModel.shared : nil }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Black blocks and white text everywhere, as in FaceID: menus, panels and alerts are dark too.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Started at login, Subline runs in the background (MainWindow).
        if Updater.LoginItem.launchedAtLogin { MainWindow.startInBackground() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainWindow.hideWindows()
        let model = AppModel.shared
        attach(model)
        DebugHooks.model = model
        connect(model.updater)
        model.updater.start()
        DebugHooks.install()
    }

    private func attach(_ model: AppModel) {
        attached = true
        WindowCloseGuard.shared.mayClose = { [weak model] in model?.confirmStopForClosing() ?? true }
        MainWindow.cameBack = { [weak self] in self?.windowCameBack() }
        if let url = pendingURLs.first {
            pendingURLs.removeAll()
            model.openMedia(url)
        } else if !DebugHooks.opensFile && !MainWindow.inBackground {
            restoreSessionSoon()
        }
        if !MainWindow.inBackground { releaseTextFocusSoon() }
    }

    /// The window is back from the background: as at a usual launch, the last video comes back unless a file is being
    /// opened, and no text field keeps the focus.
    private func windowCameBack() {
        if !DebugHooks.opensFile { restoreSessionSoon() }
        releaseTextFocusSoon()
    }

    /// The video of the last session comes back with its subtitles, unless a file is being opened from Finder.
    private func restoreSessionSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let model = self.model, self.pendingURLs.isEmpty, model.mediaURL == nil else { return }
            model.restoreLastSession()
        }
    }

    /// The window focuses its first text field on opening (a value in the inspector). Nothing is being typed yet, so take
    /// that focus back: Space and the arrows then control the player right away.
    private func releaseTextFocusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for window in NSApp.windows where window.firstResponder is NSText {
                window.makeFirstResponder(nil)
            }
        }
    }

    private func connect(_ updater: Updater) {
        // An update that installs itself restarts Subline only when that breaks nothing (AppModel.holdsWork) and no panel,
        // sheet or alert is open.
        updater.appIsBusy = { [weak self] in
            self?.model?.holdsWork == true || NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
        }
        // Such an update shows "Обновляюсь до версии…" in the window for a moment before the restart, when the window is
        // on screen (applicationShouldTerminate).
        observers.append(NotificationCenter.default.addObserver(forName: Updater.willRestart, object: updater,
                                                                queue: nil) { [weak self] note in
            let automatic = note.userInfo?["automatic"] as? Bool == true
            MainActor.assumeIsolated {
                guard automatic, !MainWindow.inBackground, MainWindow.window?.isVisible == true else { return }
                self?.restartNoticeEnd = Date().addingTimeInterval(1.5)
            }
        })
    }

    /// Subline opened from the Dock, Launchpad or Finder while it runs: the window comes back, from the background too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let window = MainWindow.window
        guard MainWindow.inBackground || window?.isVisible != true else { return true }
        MainWindow.show()
        // No window to bring back: SwiftUI opens a new one.
        return window == nil
    }

    /// Files dropped onto the Dock icon or opened with "Open With". The window comes back for them from the background.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model {
            model.requestOpen(url)
        } else {
            pendingURLs = [url]
        }
        MainWindow.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Closes sheets first: macOS refuses to quit while a sheet is open. Waits until they are gone.
    static func quit(_ model: AppModel?) {
        model?.showModelManager = false
        model?.showFontLibrary = false
        func closeSheets() {
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
        }
        func attempt(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if remaining > 0, NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                    closeSheets()
                    attempt(remaining - 1)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
        closeSheets()
        attempt(20)
    }

    /// An open sheet (model manager) would otherwise block quitting. Running recognition or export is lost on quitting,
    /// so the person is asked first; subtitles and edits are written to disk, the ones still waiting for the delayed save
    /// too. Before an update that installed itself restarts Subline, the window shows it for a moment.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, !model.confirmStopForClosing() {
            restartNoticeEnd = nil
            return .terminateCancel
        }
        model?.flushPendingSaves()
        model?.showModelManager = false
        model?.showFontLibrary = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        model?.cancelActivity()
        let notice = max(0, restartNoticeEnd?.timeIntervalSinceNow ?? 0)
        restartNoticeEnd = nil
        guard notice > 0 else { return .terminateNow }
        // While it waits for the reply, AppKit runs the main run loop in the modal panel mode.
        let timer = Timer(timeInterval: notice, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // An edit made meanwhile is written as well.
                self?.model?.flushPendingSaves()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
        return .terminateLater
    }
}

/// Test hooks driven by environment variables (used for automated UI checks):
///   SUBLINE_OPEN=<file>                       open a media file at launch
///   SUBLINE_SNAPSHOTS="3:/tmp/a.png;9:/tmp/b.png"  save window snapshots after N seconds
///   SUBLINE_ACTIONS="5:select-cue-2;6:open-models"  run actions after N seconds
///   SUBLINE_QUIT_AFTER=<seconds>
///   SUBLINE_FORCE_ACTIVE=1                     draw the window as active while it stays in the background
@MainActor
enum DebugHooks {
    static weak var model: AppModel?
    static let forceActive = ProcessInfo.processInfo.environment["SUBLINE_FORCE_ACTIVE"] != nil
    /// SUBLINE_OPEN opens a file at launch: the last session does not come back then.
    static let opensFile = ProcessInfo.processInfo.environment["SUBLINE_OPEN"] != nil
    /// The "still" action: the video shows its still frame instead of the player layer, which offscreen renders miss.
    static var stillFrame = false

    nonisolated static func install() {
        let env = ProcessInfo.processInfo.environment
        _ = MainActor.assumeIsolated { opensFile }
        // A restarted copy of the app inherits the environment and must not repeat the test actions.
        for name in ["SUBLINE_OPEN", "SUBLINE_SNAPSHOTS", "SUBLINE_ACTIONS", "SUBLINE_QUIT_AFTER"] { unsetenv(name) }
        Task { @MainActor in
            if let path = env["SUBLINE_OPEN"] {
                try? await Task.sleep(nanoseconds: 800_000_000)
                model?.openMedia(URL(fileURLWithPath: path))
            }
        }
        for (delay, value) in schedule(env["SUBLINE_SNAPSHOTS"]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { snapshot(to: value) } }
        }
        for (delay, value) in schedule(env["SUBLINE_ACTIONS"]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { perform(value) } }
        }
        if let quit = env["SUBLINE_QUIT_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + quit) { MainActor.assumeIsolated { AppDelegate.quit(model) } }
        }
    }

    nonisolated static func schedule(_ text: String?) -> [(Double, String)] {
        (text ?? "").split(separator: ";").compactMap { item in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let delay = Double(parts[0]) else { return nil }
            return (delay, parts[1])
        }
    }

    static func snapshot(to path: String) {
        for (index, window) in NSApp.windows.filter(\.isVisible).enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let suffix = window.isSheet ? "-sheet" : window.identifier?.rawValue == "main" || index == 0 ? "" : "-\(index)"
            let url = URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "\(suffix).png"))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
               let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) {
                sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
                try? sheetRep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-sheet.png")))
            }
        }
    }

    private static var standaloneWindows: [NSWindow] = []

    /// Shows a sheet's content in an ordinary window: screenshots of a window in the background fail
    /// while a sheet is attached to it.
    static func showStandalone<V: View>(_ view: V, size: CGSize) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.modifier(DebugActiveState()))
        window.center()
        window.orderFront(nil)
        standaloneWindows.append(window)
    }

    static func findPlayerLayer(in view: NSView) -> AVPlayerLayer? {
        if let playerView = view as? PlayerNSView { return playerView.playerLayer }
        for subview in view.subviews {
            if let layer = findPlayerLayer(in: subview) { return layer }
        }
        return nil
    }

    /// Renders a view in an offscreen window (for checking layouts taller than the screen).
    static func renderOffscreen<V: View>(_ view: V, size: CGSize, to path: String) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).modifier(DebugActiveState()))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // Swift owns it; close() would release it a second time
        window.contentView = hosting
        window.appearance = NSApp.effectiveAppearance
        hosting.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            window.close()
        }
    }

    static func perform(_ action: String) {
        guard let model else { return }
        let parts = action.split(separator: "=", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "open-models": model.showModelManager = true
        case "window-models":
            showStandalone(ModelManagerView().environmentObject(model).environmentObject(model.modelStore),
                           size: CGSize(width: 720, height: 620))
        case "window-settings":
            showStandalone(SettingsView().environmentObject(model.updater), size: CGSize(width: 380, height: 260))
        case "window-library":
            showStandalone(FontLibraryView().environmentObject(model).environmentObject(model.fontStore),
                           size: CGSize(width: 820, height: 680))
        case "close-sheet": model.showModelManager = false
        case "click-row":
            // click-row=<index>[+] (+ = with ⇧)
            if parts.count > 1, let index = Int(parts[1].replacingOccurrences(of: "+", with: "")), index < model.cues.count {
                model.clickRow(model.cues[index], modifiers: parts[1].hasSuffix("+") ? [.shift] : [])
            }
        case "select-cue":
            if parts.count > 1, let index = Int(parts[1]), index < model.cues.count { model.select(model.cues[index]) }
        case "preset":
            if parts.count > 1, let index = Int(parts[1]), index < model.presets.count { model.selectedPresetID = model.presets[index].id }
        case "case":
            if parts.count > 1, let mode = TextCaseMode(rawValue: parts[1]) { model.preset.caseMode = mode }
        case "lines":
            if parts.count > 1, let lines = Int(parts[1]) { model.preset.maxLines = lines }
        case "transcribe": model.startTranscription()
        case "help": model.showHelp = true
        case "download":
            if parts.count > 1, let info = ModelCatalog.model(id: parts[1]) { model.modelStore.download(info) }
        case "render-inspector":
            // render-inspector=<tab>,<path>
            if parts.count > 1 {
                let args = parts[1].split(separator: ",", maxSplits: 1).map(String.init)
                if args.count == 2, let tab = InspectorTab(rawValue: args[0]) {
                    model.inspectorTab = tab
                    renderOffscreen(InspectorView().environmentObject(model), size: CGSize(width: 300, height: 1400), to: args[1])
                }
            }
        case "render-parts":
            // render-parts=<dir>: sidebar, canvas and inspector separately at a fixed height
            if parts.count > 1 {
                let dir = parts[1]
                renderOffscreen(SidebarView().environmentObject(model).environmentObject(model.modelStore).environmentObject(model.updater),
                                size: CGSize(width: 320, height: 860), to: dir + "/part_sidebar.png")
                renderOffscreen(CanvasArea(player: model.player).environmentObject(model),
                                size: CGSize(width: 780, height: 860), to: dir + "/part_canvas.png")
                renderOffscreen(InspectorView().environmentObject(model),
                                size: CGSize(width: 300, height: 860), to: dir + "/part_inspector.png")
            }
        case "report-window":
            if parts.count > 1 {
                var lines: [String] = []
                for window in NSApp.windows {
                    lines.append("window \(type(of: window)) '\(window.title)' id=\(window.identifier?.rawValue ?? "-") visible=\(window.isVisible) \(window.frame) content \(window.contentLayoutRect) transparentTitlebar=\(window.titlebarAppearsTransparent) fullSize=\(window.styleMask.contains(.fullSizeContentView)) toolbar=\(window.toolbar != nil) bg=\(window.backgroundColor.description)")
                    func dump(_ view: NSView, _ depth: Int) {
                        guard depth < 9 else { return }
                        lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame)")
                        for sub in view.subviews { dump(sub, depth + 1) }
                    }
                    if let root = window.contentView { dump(root, 0) }
                }
                try? lines.joined(separator: "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        case "tab":
            if parts.count > 1, let tab = InspectorTab(rawValue: parts[1]) { model.inspectorTab = tab }
        case "report-language":
            // report-language=<path>: interface language and the titles of the system menus
            if parts.count > 1 {
                func titles(_ menu: NSMenu?) -> [String] { menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [] }
                let menu = NSApp.mainMenu
                let info: [String: Any] = [
                    "current": Localization.current,
                    "appleLanguages": UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] ?? "none",
                    "preferredLocalizations": Bundle.main.preferredLocalizations,
                    "menus": titles(menu),
                    "appMenu": titles(menu?.items.first?.submenu),
                    "editMenu": titles(menu?.items.count ?? 0 > 2 ? menu?.items[2].submenu : nil),
                    "windows": NSApp.windows.filter(\.isVisible).map(\.title),
                ]
                if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: parts[1]))
                }
            }
        case "report":
            // report=<path>: player state as JSON (the video layer is not captured by window snapshots).
            if parts.count > 1 {
                let layer = NSApp.windows.compactMap { $0.contentView }.compactMap { findPlayerLayer(in: $0) }.first
                let item = model.player.player.currentItem
                let info: [String: Any] = [
                    "isReady": model.player.isReady,
                    "isReadyForDisplay": layer?.isReadyForDisplay ?? false,
                    "layerBounds": layer.map { "\($0.bounds.width)x\($0.bounds.height)" } ?? "none",
                    "currentTime": model.player.currentTime,
                    "isPlaying": model.player.isPlaying,
                    "itemStatus": item?.status.rawValue ?? -1,
                    "presentationSize": item.map { "\($0.presentationSize.width)x\($0.presentationSize.height)" } ?? "none",
                    "currentCue": model.currentCue?.text ?? "",
                    "copyProgress": model.player.copyProgress ?? -1,
                    "copyFailed": model.player.copyFailed,
                    "cueCount": model.cues.count,
                    "cueStarts": model.cues.prefix(8).map { $0.start },
                    "frameRate": model.player.frameRate,
                    "maxLines": model.preset.maxLines,
                    "positionY": model.preset.positionY,
                    "undoTitle": model.undoManager?.undoActionName ?? "",
                    "scope": model.scopeTitle,
                    "groups": model.groups.map { "\($0.name):\(model.cueCount(inGroup: $0.id))" },
                    "currentCueStyled": model.currentCue?.hasCustomStyle ?? false,
                    "currentCueWordStyles": model.currentCue?.wordStyles?.keys.sorted() ?? [],
                    "installedFonts": model.fontStore.installedIDs.sorted(),
                    "bundleID": Bundle.main.bundleIdentifier ?? "",
                    "soundEffects": SoundEffects.isEnabled,
                    "menuBarIcon": MenuBarIcon.isEnabled,
                    "version": model.updater.currentVersion,
                    "developmentBuild": model.updater.isDevelopmentBuild,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: parts[1]))
                }
            }
        case "word":
            // word=<index>[+] : click a word of the subtitle under the playhead (+ = with ⇧)
            if parts.count > 1, let cue = model.currentCue {
                let extend = parts[1].hasSuffix("+")
                if let index = Int(parts[1].replacingOccurrences(of: "+", with: "")) { model.clickWord(index, in: cue, extend: extend) }
            }
        case "scope":
            if parts.count > 1 {
                switch parts[1] {
                case "all": model.scope = .all
                case "cues": model.scope = .cues
                case "words": if model.wordSelection != nil { model.scope = .words }
                case "group": if let id = model.contextGroupID { model.scope = .group(id) }
                default: break
                }
            }
        case "color":
            if parts.count > 1, let value = UInt32(parts[1], radix: 16) {
                model.setStyle(\.textColor, \.textColor, RGBAColor(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255))
            }
        case "highlight":
            if parts.count > 1, let value = UInt32(parts[1], radix: 16) {
                model.highlightBinding.wrappedValue = true
                model.setStyle(\.highlightColor, \.highlightColor, RGBAColor(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255))
            }
        case "font":
            if parts.count > 1 { model.setStyle(\.fontFamily, \.fontFamily, parts[1]) }
        case "face":
            if parts.count > 1 { model.setStyle(\.fontFace, \.fontFace, parts[1]) }
        case "size":
            if parts.count > 1, let px = Double(parts[1]) { model.pixels(\.fontSize, \.fontSize).wrappedValue = px }
        case "slant":
            if parts.count > 1, let degrees = Double(parts[1]) { model.setStyle(\.slant, \.slant, degrees) }
        case "upper": model.setStyle(\.uppercase, \.uppercase, true)
        case "pos":
            if parts.count > 1 {
                let xy = parts[1].split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 { model.setPosition(x: xy[0] / model.frameWidth, y: xy[1] / model.frameHeight) }
            }
        case "group": model.createGroup()
        case "copy-style": model.copyStyle()
        case "paste-style": model.pasteStyle()
        case "library": model.showFontLibrary = true
        case "install-font":
            if parts.count > 1, let font = FontCatalog.font(id: parts[1]) { model.fontStore.install(font) }
        case "undo": model.undoManager?.undo()
        case "redo": model.undoManager?.redo()
        case "delete-cue":
            if parts.count > 1, let index = Int(parts[1]), index < model.cues.count { model.deleteCue(model.cues[index].id) }
        case "play": model.player.play()
        case "pause": model.player.pause()
        case "step":
            if parts.count > 1, let frames = Int(parts[1]) { model.player.step(frames: frames) }
        case "seek":
            if parts.count > 1, let time = Double(parts[1]) { model.player.seek(to: time) }
        case "render-models":
            if parts.count > 1 {
                renderOffscreen(ModelManagerView().environmentObject(model).environmentObject(model.modelStore),
                                size: CGSize(width: 620, height: 560), to: parts[1])
            }
        case "render-settings":
            if parts.count > 1 {
                let view = SettingsView().environmentObject(model.updater)
                renderOffscreen(view, size: NSHostingView(rootView: view).fittingSize, to: parts[1])
            }
        case "render-glyph":
            // render-glyph=<marks typed>,<path>: the menu bar icon during recognition, white, 8 pixels per point
            let args = parts.count > 1 ? parts[1].split(separator: ",", maxSplits: 1).map(String.init) : []
            guard args.count == 2, let typed = Double(args[0]) else { break }
            let image = WorkGlyph.image(.typing(typed))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 8),
                                             pixelsHigh: Int(image.size.height * 8), bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                             bitsPerPixel: 0) else { break }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let rect = NSRect(origin: .zero, size: image.size)
            image.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
        case "activity":
            // activity=<transcribing|exporting>,<0…1>: the window shows a long job without running it. Only while the
            // menu bar icon is off, so nothing appears outside the window.
            let args = parts.count > 1 ? parts[1].split(separator: ",", maxSplits: 1).map(String.init) : []
            if args.count == 2, let progress = Double(args[1]), !MenuBarIcon.isEnabled {
                let exporting = args[0] == "exporting"
                model.stageActivity(Activity(kind: exporting ? .exporting : .transcribing,
                                             title: exporting ? L("Готовлю субтитры") : L("Распознаю речь"), progress: progress))
            }
        case "outline":
            if parts.count > 1 { model.setStyle(\.outlineEnabled, \.outlineEnabled, parts[1] == "1") }
        case "shadow":
            if parts.count > 1 { model.setStyle(\.shadowEnabled, \.shadowEnabled, parts[1] == "1") }
        case "box":
            if parts.count > 1, let mode = BoxMode(rawValue: parts[1]) { model.setStyle(\.boxMode, \.boxMode, mode) }
        case "render-main":
            // render-main=<width>,<height>,<path>: the whole window content, offscreen
            let args = parts.count > 1 ? parts[1].split(separator: ",", maxSplits: 2).map(String.init) : []
            if args.count == 3, let width = Double(args[0]), let height = Double(args[1]) {
                renderOffscreen(MainView().environmentObject(model).environmentObject(model.modelStore)
                                    .environmentObject(model.fontStore).environmentObject(model.updater),
                                size: CGSize(width: width, height: height), to: args[2])
            }
        case "render-library":
            if parts.count > 1 {
                renderOffscreen(FontLibraryView().environmentObject(model).environmentObject(model.fontStore),
                                size: CGSize(width: 760, height: 640), to: parts[1])
            }
        case "still":
            stillFrame = true
        case "export":
            if parts.count > 1 { model.exportForTesting(.mp4H264, to: URL(fileURLWithPath: parts[1])) }
        default: break
        }
    }
}

/// SUBLINE_FORCE_ACTIVE=1: controls look as in the active window (screenshots of a window kept in the background).
private struct DebugActiveState: ViewModifier {
    func body(content: Content) -> some View {
        if DebugHooks.forceActive {
            content.environment(\.controlActiveState, .key)
        } else {
            content
        }
    }
}
