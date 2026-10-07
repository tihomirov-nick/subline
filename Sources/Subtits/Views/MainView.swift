import SwiftUI
import UniformTypeIdentifiers
import SubtitsCore

/// Window layout in the familiar Apple editor arrangement: navigator (subtitles) on the left,
/// the viewer in the middle, the style inspector on the right.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 440)
        } detail: {
            HStack(spacing: 0) {
                CanvasArea(player: model.player)
                if model.showInspector {
                    Divider()
                    InspectorView()
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.showOpenPanel()
                } label: {
                    Label(L("Открыть видео"), systemImage: "plus.rectangle.on.folder")
                }
                .help(L("Открыть видео (⌘O)"))
                .disabled(model.isExporting)
            }
            // The main action of the window: tinted glass.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title) { model.export(format) }
                            .disabled(format.needsVideo && !model.hasVideo)
                    }
                } label: {
                    Label(L("Экспорт"), systemImage: "square.and.arrow.up")
                } primaryAction: {
                    model.export(model.media == nil || model.hasVideo ? .mp4H264 : .srt)
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .labelStyle(.titleAndIcon)
                .help(L("Сохранить видео с субтитрами (⌘E). Другие форматы в меню под стрелкой"))
                .disabled(model.cues.isEmpty || model.isBusy)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(Motion.animation(Motion.standard, reduceMotion: reduceMotion)) {
                        model.showInspector.toggle()
                    }
                } label: {
                    Label(L("Инспектор"), systemImage: "sidebar.right")
                }
                .help(L("Показать или скрыть стиль субтитров (⌥⌘I)"))
            }
        }
        .navigationTitle(model.mediaURL?.lastPathComponent ?? "Subtits")
        .navigationSubtitle(model.media?.summary ?? (model.mediaURL == nil ? L("Перетащите видео в окно") : ""))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted.animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion))) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                DropHighlight()
                    .transition(.materialize(reduceMotion: reduceMotion))
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

private struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(0.1)))
            Label(L("Отпустите, чтобы открыть видео"), systemImage: "film")
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .glassSurface(Capsule())
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}
