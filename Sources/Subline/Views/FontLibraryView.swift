import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers
import SublineCore

/// Popular fonts for subtitles: free ones install with one click, paid ones open the foundry's site.
/// Search and categories on top, cards with real previews below. Font files can be dropped onto the sheet.
struct FontLibraryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var fontStore: FontStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var category: CatalogFont.Category?
    @State private var search = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L("Библиотека шрифтов"),
                        help: L("Бесплатные шрифты с кириллицей ставятся в один клик и работают без интернета. Встроенные есть на любом Mac с Subline"),
                        accessory: {
                            SearchField(prompt: L("Поиск"), text: $search)
                                .frame(width: 180)
                        },
                        done: { dismiss() })
            ScrollView(.horizontal, showsIndicators: false) {
                Segments(selection: $category,
                         items: [SegmentItem<CatalogFont.Category?>(nil, L("Все"))]
                            + CatalogFont.Category.allCases.map { SegmentItem<CatalogFont.Category?>($0, $0.title) },
                         large: true)
                    .padding(.horizontal, Metrics.inset + 2)
            }
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(section.title)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                ForEach(section.fonts) { font in
                                    FontCard(font: font)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Metrics.inset + 2)
                .padding(.bottom, Metrics.inset)
                .id(category)
                .transition(.reveal(reduceMotion: reduceMotion))
            }
            .animation(Motion.animation(Motion.island, reduceMotion: reduceMotion), value: category)
            Separator(leading: 0)
            HStack(spacing: 8) {
                Button(L("Добавить файлы шрифтов…")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.font, UTType(filenameExtension: "otf"), UTType(filenameExtension: "ttf")].compactMap { $0 }
                    panel.allowsMultipleSelection = true
                    AppModel.present(panel) { panel in
                        importFiles((panel as? NSOpenPanel)?.urls ?? [])
                    }
                }
                .appButton(.secondary)
                .controlSize(.small)
                .help(L("Файлы .otf и .ttf можно и просто перетащить в это окно. Шрифты, установленные в macOS, уже есть в списке шрифтов"))
                Spacer(minLength: 8)
                if let error = fontStore.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.danger)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(error)
                }
            }
            .padding(.horizontal, Metrics.inset + 2)
            .padding(.vertical, Metrics.inset)
        }
        .frame(width: 760, height: 640)
        .background(Palette.block)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in importFiles([url]) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Metrics.blockRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, dash: [10, 7]))
                    .background(RoundedRectangle(cornerRadius: Metrics.blockRadius, style: .continuous).fill(Color.white.opacity(0.06)))
                    .padding(Metrics.gap)
                    .allowsHitTesting(false)
            }
        }
    }

    private struct Section {
        let title: String
        let fonts: [CatalogFont]
    }

    private var sections: [Section] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = FontCatalog.fonts.filter { query.isEmpty || $0.family.localizedCaseInsensitiveContains(query) }
        if let category {
            return [Section(title: category.title, fonts: matching.filter { $0.category == category })]
        }
        var result: [Section] = []
        if query.isEmpty {
            result.append(Section(title: L("Популярные в Reels"), fonts: matching.filter { $0.popular && !$0.isCommercial }))
        }
        for item in CatalogFont.Category.allCases {
            let fonts = matching.filter { $0.category == item }
            if !fonts.isEmpty { result.append(Section(title: item.title, fonts: fonts)) }
        }
        return result
    }

    private func importFiles(_ urls: [URL]) {
        let families = fontStore.importFiles(urls)
        if let family = families.first, !FontLibrary.isAvailable(family: model.effectiveStyle.fontFamily) || families.contains(model.preset.fontFamily) {
            model.setStyle(\.fontFamily, \.fontFamily, family)
        }
    }
}

private struct FontCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var fontStore: FontStore
    let font: CatalogFont
    @State private var hovering = false

    var body: some View {
        let installed = fontStore.installedIDs.contains(font.id)
        let progress = fontStore.installing[font.id]
        let family = installed ? fontStore.familyName(of: font) : font.family
        let inUse = model.effectiveStyle.fontFamily == family
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(font.family)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if font.bundled { Badge(text: L("Встроен"), color: Color(red: 0.45, green: 0.9, blue: 0.55)) }
                if font.isCommercial { Badge(text: L("Платный"), color: Palette.attention) }
                if !font.cyrillic { Badge(text: L("Латиница"), color: Palette.danger) }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.russianSample)
                    .font(sampleFont(installed: installed, family: family, size: 18))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(Self.englishSample)
                    .font(sampleFont(installed: installed, family: family, size: 14))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(hasPreview(installed) ? Color.white : Palette.tertiary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                if !hasPreview(installed) && !font.isCommercial {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(font.details)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .help(font.details)
            HStack(spacing: 8) {
                if let progress {
                    ProgressLine(value: progress)
                        .frame(width: 110)
                    Text(L("Скачиваю…"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                } else if case .commercial(let url, let vendor) = font.source {
                    Button(L("Купить на сайте %@", "\(vendor)")) { NSWorkspace.shared.open(url) }
                        .appButton(.secondary)
                        .fixedSize()
                        .help(installed ? "" : L("Купите шрифт, потом перетащите его файлы в это окно"))
                    if installed {
                        applyButton(family: family, inUse: inUse)
                    }
                } else if installed {
                    applyButton(family: family, inUse: inUse)
                    if !font.bundled {
                        IconButton(symbol: "trash", help: L("Удалить шрифт"), size: 24) {
                            fontStore.remove(font)
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                } else {
                    Button(L("Скачать")) { fontStore.install(font) }
                        .appButton(.secondary)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .frame(height: 26)
        }
        .padding(12)
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(inUse ? 0.85 : 0), lineWidth: 1.5)
        )
        // An installed font is applied by a click anywhere on its card, not only on "Apply".
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .onTapGesture {
            if installed && !inUse { model.setStyle(\.fontFamily, \.fontFamily, family) }
        }
        .onHover { hovering = $0 }
        .onAppear { fontStore.requestPreview(font) }
    }

    /// The beginnings of the classic pangrams, short enough for one line.
    static let russianSample = "Съешь этих мягких булок"
    static let englishSample = "The quick brown fox jumps"

    private func hasPreview(_ installed: Bool) -> Bool {
        installed || fontStore.previews[font.id] != nil
    }

    /// The real font: installed, or loaded just for the preview.
    private func sampleFont(installed: Bool, family: String, size: CGFloat) -> Font {
        if installed { return .custom(family, size: size) }
        if let descriptor = fontStore.previews[font.id] {
            return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
        }
        return .system(size: size, weight: .medium)
    }

    @ViewBuilder
    private func applyButton(family: String, inUse: Bool) -> some View {
        if inUse {
            Label(L("Используется"), systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 2)
        } else {
            Button(L("Применить")) {
                model.setStyle(\.fontFamily, \.fontFamily, family)
            }
            .appButton(.primary)
            .help(L("Поставить этот шрифт: %@", "\(model.scopeTitle.lowercased())"))
        }
    }
}
