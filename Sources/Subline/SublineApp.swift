import SwiftUI
import AppKit
import AVFoundation
import SublineCore

@main
struct SublineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

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
                .onAppear {
                    appDelegate.attach(model)
                    DebugHooks.model = model
                }
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
            }
            CommandGroup(after: .newItem) {
                Button(L("Сохранить видео с субтитрами…")) { model.export(model.hasVideo ? .mp4H264 : .srt) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.cues.isEmpty || model.isBusy || model.updateInProgress)
                Menu(L("Экспорт в формате")) {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title) { model.export(format) }
                            .disabled(model.cues.isEmpty || model.isBusy || model.updateInProgress || (format.needsVideo && !model.hasVideo))
                    }
                }
                Divider()
                Button(L("Закрыть видео")) { model.closeMedia() }
                    .disabled(model.mediaURL == nil || model.isBusy)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? L("Скрыть стиль") : L("Показать стиль")) {
                    withAnimation(Motion.island) { model.showInspector.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            // Space and the arrow keys work in the window itself (except while typing text).
            CommandMenu(L("Воспроизведение")) {
                Button(model.player.isPlaying ? L("Пауза   (пробел)") : L("Воспроизвести   (пробел)")) { model.player.togglePlay() }
                    .disabled(!model.player.isReady)
                Divider()
                Button(L("Кадр вперед   (→)")) { model.player.step(frames: 1) }
                    .disabled(!model.hasMedia)
                Button(L("Кадр назад   (←)")) { model.player.step(frames: -1) }
                    .disabled(!model.hasMedia)
                Button(L("Секунда вперед   (⇧→)")) { model.player.seek(to: model.player.currentTime + 1) }
                    .disabled(!model.hasMedia)
                Button(L("Секунда назад   (⇧←)")) { model.player.seek(to: model.player.currentTime - 1) }
                    .disabled(!model.hasMedia)
                Divider()
                Button(L("Следующий субтитр   (↓)")) { model.selectAdjacentCue(1) }
                    .disabled(model.cues.isEmpty)
                Button(L("Предыдущий субтитр   (↑)")) { model.selectAdjacentCue(-1) }
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
                Button(L("Распознать речь")) { model.startTranscription() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.media == nil || model.isBusy || model.updateInProgress)
                Button(L("Пересобрать по пресету")) { model.rebuildCues() }
                    .disabled(model.transcript == nil || model.isBusy)
                Button(L("Разделить субтитр по курсору")) { model.splitCurrentCue() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(model.currentCue == nil)
                Divider()
                Button(L("Модели распознавания…")) { model.showModelManager = true }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model.updater)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var pendingURLs: [URL] = []

    @MainActor
    func attach(_ model: AppModel) {
        self.model = model
        if let url = pendingURLs.first {
            pendingURLs.removeAll()
            model.openMedia(url)
        }
        // The window focuses its first text field on opening (a value in the inspector). Nothing is being
        // typed yet, so take that focus back: Space and the arrows then control the player right away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for window in NSApp.windows where window.firstResponder is NSText {
                window.makeFirstResponder(nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in
            if let model = self.model {
                model.openMedia(url)
            } else {
                self.pendingURLs = [url]
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Black blocks and white text everywhere, as in FaceID: menus, panels and alerts are dark too.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugHooks.install()
    }

    /// Closes sheets first: macOS refuses to quit while a sheet is open. Waits until they are gone.
    @MainActor
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

    /// An open sheet (model manager) would otherwise block quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            model?.flushPendingSaves()
            model?.showModelManager = false
            model?.showFontLibrary = false
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            model?.cancelActivity()
        }
        return .terminateNow
    }
}

/// Test hooks driven by environment variables (used for automated UI checks):
///   SUBLINE_OPEN=<file>                       open a media file at launch
///   SUBLINE_SNAPSHOTS="3:/tmp/a.png;9:/tmp/b.png"  save window snapshots after N seconds
///   SUBLINE_ACTIONS="5:select-cue-2;6:open-models"  run actions after N seconds
///   SUBLINE_QUIT_AFTER=<seconds>
///   SUBLINE_FORCE_ACTIVE=1                     draw the window as active while it stays in the background
///   SUBLINE_SOUND_LOG=<file>                   write down every sound effect and the file it came from
///   SUBLINE_UPDATE_API=<url> SUBLINE_UPDATE_REPO=<owner/repo>   look for updates there instead of GitHub
@MainActor
enum DebugHooks {
    static weak var model: AppModel?
    static let updateRepo = ProcessInfo.processInfo.environment["SUBLINE_UPDATE_REPO"] ?? "tihomirov-nick/subline"
    static let updateAPI = ProcessInfo.processInfo.environment["SUBLINE_UPDATE_API"].flatMap(URL.init(string:))
        ?? URL(string: "https://api.github.com")!
    /// SwiftUI's own way to open Settings (macOS 14 and later), registered by the main window.
    static var openSettings: (() -> Void)?
    static let forceActive = ProcessInfo.processInfo.environment["SUBLINE_FORCE_ACTIVE"] != nil

    nonisolated static func install() {
        let env = ProcessInfo.processInfo.environment
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
        if let path = env["SUBLINE_SOUND_LOG"] {
            FileManager.default.createFile(atPath: path, contents: nil)
            SoundEffects.observer = { event, source in
                guard let file = FileHandle(forWritingAtPath: path) else { return }
                file.seekToEndOfFile()
                file.write(Data("\(event) \(source)\n".utf8))
                try? file.close()
            }
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
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
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
            if parts.count > 1, let index = Int(parts[1]), index < model.cues.count { model.clickRow(model.cues[index], modifiers: []) }
        case "select-cue":
            if parts.count > 1, let index = Int(parts[1]), index < model.cues.count { model.select(model.cues[index]) }
        case "preset":
            if parts.count > 1, let index = Int(parts[1]), index < model.presets.count { model.selectedPresetID = model.presets[index].id }
        case "case":
            if parts.count > 1, let mode = TextCaseMode(rawValue: parts[1]) { model.preset.caseMode = mode }
        case "lines":
            if parts.count > 1, let lines = Int(parts[1]) { model.preset.maxLines = lines }
        case "transcribe": model.startTranscription()
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
        case "settings":
            if let openSettings {
                openSettings()
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
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
        case "outline": model.setStyle(\.outlineEnabled, \.outlineEnabled, parts.count < 2 || parts[1] != "0")
        case "shadow": model.setStyle(\.shadowEnabled, \.shadowEnabled, parts.count < 2 || parts[1] != "0")
        case "box":
            if parts.count > 1, let mode = BoxMode(rawValue: parts[1]) { model.setStyle(\.boxMode, \.boxMode, mode) }
        case "window-size":
            // window-size=<width>,<height> in points, keeping the top left corner
            if parts.count > 1 {
                let size = parts[1].split(separator: ",").compactMap { Double($0) }
                if size.count == 2, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Subline" }) {
                    var frame = window.frame
                    frame.origin.y += frame.height - size[1]
                    frame.size = CGSize(width: size[0], height: size[1])
                    window.setFrame(frame, display: true)
                }
            }
        case "pos":
            if parts.count > 1 {
                let xy = parts[1].split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 { model.setPosition(x: xy[0] / model.frameWidth, y: xy[1] / model.frameHeight) }
            }
        case "group": model.createGroup()
        case "fake-activity":
            // fake-activity=<title>|<progress or ->[|opening or exporting]
            if parts.count > 1 {
                let args = parts[1].split(separator: "|", maxSplits: 2).map(String.init)
                let kind: Activity.Kind = args.count < 3 ? .transcribing : args[2] == "opening" ? .opening : .exporting
                model.debugShowActivity(kind, title: args[0], progress: args.count > 1 ? Double(args[1]) : nil)
            }
        case "render-menubar":
            // render-menubar=<dir>: every face of the menu bar icon
            if parts.count > 1 { MenuBarIcon.renderFaces(to: URL(fileURLWithPath: parts[1])) }
        case "menubar-display":
            // menubar-display=sleep|wake: what the icon hears when the display sleeps (only inside Subline)
            let name = parts.count > 1 && parts[1] == "wake" ? NSWorkspace.screensDidWakeNotification : NSWorkspace.screensDidSleepNotification
            NSWorkspace.shared.notificationCenter.post(name: name, object: NSWorkspace.shared)
        case "menubar-finish":
            // menubar-finish=success|failure: ends a fake activity the way real work ends
            model.menuBarIcon.finish(parts.count > 1 && parts[1] == "failure" ? .failure : .success)
            model.cancelActivity()
        case "update-check": model.updater.check(userInitiated: true)
        case "update-install": model.updater.install()
        case "update-cancel": model.updater.cancel()
        case "update-dismiss": model.updater.dismiss()
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
                                size: CGSize(width: 720, height: 620), to: parts[1])
            }
        case "export":
            // export=<file>: a video in MP4 (H.264), or subtitles when the file ends in .srt
            if parts.count > 1 {
                let url = URL(fileURLWithPath: parts[1])
                model.exportForTesting(url.pathExtension == "srt" ? .srt : .mp4H264, to: url)
            }
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

/// Hands SwiftUI's Settings action to the test hooks.
@available(macOS 14.0, *)
struct SettingsOpenerHook: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear { DebugHooks.openSettings = { openSettings() } }
    }
}
