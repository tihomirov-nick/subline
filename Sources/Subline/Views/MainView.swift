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
                    .environment(\.fileIsDragged, dropTargeted)
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
        .sheet(isPresented: $model.showHelp) {
            HelpView()
        }
        .sheet(isPresented: Binding(get: { model.problemDetails != nil }, set: { if !$0 { model.problemDetails = nil } })) {
            ProblemDetailsView(text: model.problemDetails ?? "")
        }
        // A failure says what happened in the title; the technical text is one click further.
        .alert(model.problem?.title ?? model.infoMessage?.title ?? "", isPresented: Binding(
            get: { model.problem != nil || model.infoMessage != nil },
            set: { if !$0 { model.problem = nil; model.infoMessage = nil } }
        )) {
            // OK stays the default button (Return) next to «Подробнее…».
            Button("OK", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            if let details = model.problem?.details {
                Button(L("Подробнее…")) {
                    // After the alert has gone: one sheet at a time.
                    DispatchQueue.main.async { model.problemDetails = details }
                }
            }
        } message: {
            Text(model.problem?.message ?? model.infoMessage?.text ?? "")
        }
        .background {
            // A question before an action that loses work (on a view of its own: one alert per view).
            Color.clear.alert(model.confirmation?.title ?? "", isPresented: Binding(
                get: { model.confirmation != nil },
                set: { if !$0 { model.confirmation = nil } }
            ), presenting: model.confirmation) { question in
                Button(question.confirm, role: question.destructive ? .destructive : nil) { question.action() }
                Button(L("Отмена"), role: .cancel) {}
            } message: { question in
                Text(question.message)
            }
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
                model.requestOpen(url)
            }
        }
        return true
    }
}

/// The strip at the top, in the titlebar: the window's own buttons, the file, opening and saving. Its empty parts
/// move the window. It watches the model and passes what it shows on as a value: the strip itself redraws only when
/// that changes, not on every letter typed or style value tried.
private struct TopBar: View {
    @EnvironmentObject var model: AppModel
    let chrome: WindowChrome

    var body: some View {
        let _ = RenderCount.hit("TopBar")
        TopBarContent(model: model, chrome: chrome, inputs: .init(
            title: model.mediaURL?.lastPathComponent ?? "Subline",
            summary: model.media?.summary,
            showsSaved: !model.cues.isEmpty,
            savedFlash: model.savedFlash,
            isExporting: model.isExporting,
            // Always takes the click: when export cannot run, the click says why (the tooltip says it too).
            exportBlocker: model.exportBlocker(),
            exportsSubtitlesOnly: model.hasMedia && !model.hasVideo,
            showInspector: model.showInspector))
        .equatable()
    }
}

private struct TopBarContent: View, Equatable {
    struct Inputs: Equatable {
        let title: String
        let summary: String?
        let showsSaved: Bool
        let savedFlash: Int
        let isExporting: Bool
        let exportBlocker: String?
        let exportsSubtitlesOnly: Bool
        let showInspector: Bool
    }

    let model: AppModel
    let chrome: WindowChrome
    let inputs: Inputs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.chrome == rhs.chrome && lhs.inputs == rhs.inputs
    }

    var body: some View {
        let _ = RenderCount.hit("TopBarContent")
        HStack(spacing: 8) {
            title
            Spacer(minLength: 12)
            Button(L("Открыть")) {
                model.showOpenPanel()
            }
            .appButton(.secondary)
            .help(L("Открыть видео (⌘O)"))
            .disabled(inputs.isExporting)
            SplitButton(title: L("Экспорт"),
                        help: inputs.exportBlocker ?? (inputs.exportsSubtitlesOnly ? L("Экспортировать субтитры в SRT (⌘E)")
                                                                                   : L("Экспортировать видео с субтитрами (⌘E)")),
                        menuHelp: L("Другие форматы"),
                        dimmed: inputs.exportBlocker != nil,
                        action: { [model] in model.export(model.defaultExportFormat) },
                        entries: { [model] in
                            ExportFormat.allCases.map { format in
                                .item(format.title) { model.export(format) }
                            }
                        })
            IconButton(symbol: "sidebar.right", help: inputs.showInspector ? L("Скрыть стиль (⌥⌘I)") : L("Показать стиль (⌥⌘I)"),
                       size: 28, filled: inputs.showInspector) {
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

    /// The file name, its summary and the saved mark. In a narrow window the summary gives way first, then the name
    /// shortens in the middle; the summary never shrinks to a letter.
    private var title: some View {
        TitleLayout(spacing: 8) {
            Text(inputs.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .allowsHitTesting(false)
                .layoutValue(key: TitlePart.self, value: .name)
            if let summary = inputs.summary {
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .frame(minWidth: 0, alignment: .leading)
                    .clipped()
                    .allowsHitTesting(false)
                    .layoutValue(key: TitlePart.self, value: .summary)
            }
            if inputs.showsSaved {
                SavedMark(flash: inputs.savedFlash)
                    .layoutValue(key: TitlePart.self, value: .mark)
            }
        }
    }
}

/// Which part of the title a view is.
private enum TitlePart: LayoutValueKey {
    case name, summary, mark
    static let defaultValue = TitlePart.name
}

/// Lays out the title in one line on the first text baseline: everything at its own width when it fits; otherwise
/// without the summary (given no width), and the name takes what remains. Unlike ViewThatFits it measures each part
/// once instead of building and measuring two versions of the title on every layout pass of the window.
private struct TitleLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let parts = arrange(width: proposal.width, subviews: subviews)
        return CGSize(width: parts.width, height: parts.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = arrange(width: bounds.width, subviews: subviews)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = parts.widths[index]
            let dimensions = subview.dimensions(in: ProposedViewSize(width: width, height: nil))
            let y = bounds.minY + parts.baseline - dimensions[VerticalAlignment.firstTextBaseline]
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
            if width > 0 { x += width + spacing }
        }
    }

    /// The width of each part, the line's width and height, and where the baseline is.
    private func arrange(width available: CGFloat?, subviews: Subviews) -> (widths: [CGFloat], width: CGFloat, height: CGFloat, baseline: CGFloat) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let kinds = subviews.map { $0[TitlePart.self] }
        func total(_ widths: [CGFloat]) -> CGFloat {
            let shown = widths.filter { $0 > 0 }
            return shown.reduce(0, +) + spacing * CGFloat(max(0, shown.count - 1))
        }
        var widths = ideal
        if let available, total(widths) > available {
            // The summary goes first, then the name shortens.
            for index in kinds.indices where kinds[index] == .summary { widths[index] = 0 }
            if let name = kinds.firstIndex(of: .name) {
                let others = widths.indices.filter { $0 != name && widths[$0] > 0 }
                let taken = others.reduce(0) { $0 + widths[$1] } + spacing * CGFloat(others.count)
                widths[name] = max(0, min(ideal[name], available - taken))
            }
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        for (index, subview) in subviews.enumerated() where widths[index] > 0 {
            let dimensions = subview.dimensions(in: ProposedViewSize(width: widths[index], height: nil))
            ascent = max(ascent, dimensions[VerticalAlignment.firstTextBaseline])
            descent = max(descent, dimensions.height - dimensions[VerticalAlignment.firstTextBaseline])
        }
        return (widths, total(widths), ascent + descent, ascent)
    }
}

/// The work is written to disk by itself: nothing to save by hand before closing. ⌘S lights the mark up for a moment.
private struct SavedMark: View {
    let flash: Int
    @State private var lit = false

    var body: some View {
        Label(L("Сохранено"), systemImage: "checkmark")
            .font(.system(size: 11.5))
            .foregroundStyle(lit ? Color.white : Palette.tertiary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .help(L("Субтитры и правки сохраняются сами. Если закрыть Subline, при следующем запуске это видео откроется вместе с ними"))
            .onChange(of: flash) { _ in
                withAnimation(.easeOut(duration: 0.15)) { lit = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeOut(duration: 0.6)) { lit = false }
                }
            }
    }
}

extension EnvironmentValues {
    /// A file is being dragged over the window: the card in the middle of the video makes way for the drop outline.
    var fileIsDragged: Bool {
        get { self[FileIsDraggedKey.self] }
        set { self[FileIsDraggedKey.self] = newValue }
    }
}

private struct FileIsDraggedKey: EnvironmentKey {
    static let defaultValue = false
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
