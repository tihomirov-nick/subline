import SwiftUI
import UniformTypeIdentifiers
import SublineCore

/// The window: a top bar with the file and the main actions, then three black blocks on graphite: recognition and
/// subtitles on the left, the video in the middle, the style on the right.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    @State private var chrome = WindowChrome()
    @State private var dropTargeted = false
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 300
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            TopBar(chrome: chrome)
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: sidebarWidth)
                    .block()
                ResizeHandle(width: $sidebarWidth)
                CanvasArea(player: model.player)
                    .block()
                if model.showInspector {
                    InspectorView()
                        .frame(width: 300)
                        .block()
                        .padding(.leading, Metrics.gap)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Metrics.gap)
            .padding(.bottom, Metrics.gap)
        }
        .background(Palette.window)
        .background(WindowConfigurator(chrome: $chrome))
        .background {
            if #available(macOS 14.0, *) { SettingsOpenerHook() }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted.animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion))) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                DropHighlight()
                    .transition(.reveal(reduceMotion: reduceMotion))
            }
        }
        .sheet(isPresented: $model.showModelManager) {
            ModelManagerView()
                .environmentObject(model)
                .environmentObject(modelStore)
        }
        .sheet(isPresented: $model.showFontLibrary) {
            FontLibraryView()
                .environmentObject(model)
                .environmentObject(model.fontStore)
        }
        .alert(L("Ошибка"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: modelStore.installed) { _ in
            model.ensureValidModelSelection()
        }
        .onAppear { model.undoManager = undoManager }
        .onReceive(NotificationCenter.default.publisher(for: .openFontLibrary)) { _ in
            model.showFontLibrary = true
        }
        .onChange(of: undoManager) { model.undoManager = $0 }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                model.openMedia(url)
            }
        }
        return true
    }
}

/// The strip at the top, in the titlebar: the window's own buttons, the file, opening and saving. Its empty parts
/// move the window.
private struct TopBar: View {
    @EnvironmentObject var model: AppModel
    let chrome: WindowChrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            title
            Spacer(minLength: 12)
            Button(L("Открыть")) {
                model.showOpenPanel()
            }
            .appButton(.secondary)
            .help(L("Открыть видео (⌘O)"))
            .disabled(model.isExporting)
            SplitButton(title: L("Экспорт"),
                        help: L("Сохранить видео с субтитрами (⌘E)"),
                        menuHelp: L("Другие форматы"),
                        action: { model.export(model.media == nil || model.hasVideo ? .mp4H264 : .srt) },
                        entries: {
                            ExportFormat.allCases.map { format in
                                .item(format.title, enabled: !format.needsVideo || model.hasVideo) { model.export(format) }
                            }
                        })
                .disabled(model.cues.isEmpty || model.isBusy || model.updateInProgress)
            IconButton(symbol: "sidebar.right", help: model.showInspector ? L("Скрыть стиль (⌥⌘I)") : L("Показать стиль (⌥⌘I)"),
                       size: 28, filled: model.showInspector) {
                withAnimation(Motion.animation(Motion.island, reduceMotion: reduceMotion)) {
                    model.showInspector.toggle()
                }
            }
        }
        .padding(.leading, chrome.fullScreen ? 14 : chrome.controlsEnd + 14)
        .padding(.trailing, Metrics.gap + 4)
        .frame(height: chrome.titlebarHeight)
        .background(WindowDragArea())
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.mediaURL?.lastPathComponent ?? "Subline")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let summary = model.media?.summary {
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The gap between the subtitles and the video: dragging it makes the subtitles wider or narrower.
private struct ResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Metrics.gap)
            .overlay {
                Capsule()
                    .fill(Color.white.opacity(hovering || start != nil ? 0.3 : 0))
                    .frame(width: 2, height: 36)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if start == nil { start = width }
                        width = min(max((start ?? width) + value.translation.width, 260), 440)
                    }
                    .onEnded { _ in start = nil }
            )
            .animation(.easeOut(duration: 0.15), value: hovering)
            .help(L("Потяните, чтобы изменить ширину"))
    }
}

private struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.blockRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, dash: [10, 7]))
                .background(RoundedRectangle(cornerRadius: Metrics.blockRadius, style: .continuous).fill(Color.white.opacity(0.06)))
            Label(L("Отпустите, чтобы открыть видео"), systemImage: "film")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.black))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        }
        .padding(Metrics.gap)
        .allowsHitTesting(false)
    }
}
