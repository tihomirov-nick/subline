import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers
import SubtitsCore

/// Popular fonts for subtitles: free ones install with one click, commercial ones open the foundry's site.
/// Category chips and a search capsule on top, a grid of cards with real previews below.
struct FontLibraryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var fontStore: FontStore
    @Environment(\.dismiss) private var dismiss
    @State private var category: CatalogFont.Category?
    @State private var search = ""
    @State private var dropTargeted = false

    var body: some View {
        BarredScroll {
            header
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 14)
        } content: {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 4)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(section.fonts) { font in
                                FontCard(font: font)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 22)
        } footer: {
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 820, height: 680)
        .background(Color.groupedBackground)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(symbol: "textformat", color: .orange,
                        title: L("Библиотека шрифтов"),
                        subtitle: L("Бесплатные шрифты с кириллицей ставятся в один клик и работают без интернета. Встроенные есть на любом Mac с Subtits.")) {
                Button(L("Готово")) { dismiss() }
                    .glassProminentButton()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 10) {
                SearchField(prompt: L("Поиск"), text: $search)
                    .frame(width: 200)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(L("Все"), nil)
                        ForEach(CatalogFont.Category.allCases) { item in
                            chip(item.title, item)
                        }
                    }
                    .padding(.vertical, 1)
                    .padding(.trailing, 24)
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            }
        }
    }

    /// Filter chip: filled with the accent color when chosen.
    private func chip(_ title: String, _ value: CatalogFont.Category?) -> some View {
        let selected = category == value
        return Button {
            withAnimation(Motion.quick) { category = value }
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Capsule().fill(selected ? Color.accentColor : Color.quietFill))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.font, UTType(filenameExtension: "otf"), UTType(filenameExtension: "ttf")].compactMap { $0 }
                panel.allowsMultipleSelection = true
                guard panel.runModal() == .OK else { return }
                importFiles(panel.urls)
            } label: {
                Label(L("Добавить файлы шрифтов…"), systemImage: "plus")
            }
            .glassButton()
            Text(L("Или перетащите файлы .otf и .ttf в это окно. Шрифты, установленные в macOS, тоже есть в списке шрифтов."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let error = fontStore.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 240, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(font.family)
                    .font(.system(size: 14, weight: .semibold))
                if font.bundled { Badge(text: L("Встроен"), color: .green) }
                if font.isCommercial { Badge(text: L("Платный"), color: .orange) }
                if !font.cyrillic { Badge(text: L("Только латиница"), color: .red) }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.russianSample)
                    .font(sampleFont(installed: installed, family: family, size: 19))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.englishSample)
                    .font(sampleFont(installed: installed, family: family, size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(hasPreview(installed) ? Color.primary : Color.secondary.opacity(0.55))
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                if !hasPreview(installed) && !font.isCommercial {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(font.details)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                    Text(L("Скачиваю…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if case .commercial(let url, let vendor) = font.source {
                    Button(L("Купить на сайте %@", "\(vendor)")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(TintedCapsuleButtonStyle(color: .orange))
                    if installed {
                        applyButton(family: family, inUse: inUse)
                    } else {
                        Text(L("потом перетащите файлы сюда"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                } else if installed {
                    applyButton(family: family, inUse: inUse)
                    if !font.bundled {
                        Button {
                            fontStore.remove(font)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(RoundIconButtonStyle())
                        .help(L("Удалить шрифт"))
                        .opacity(hovering ? 1 : 0)
                    }
                } else {
                    Button {
                        fontStore.install(font)
                    } label: {
                        Label(L("Скачать"), systemImage: "arrow.down")
                    }
                    .buttonStyle(TintedCapsuleButtonStyle())
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(14)
        .card(radius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: inUse ? 2 : 0)
        )
        .onHover { hovering = $0 }
        .onAppear { fontStore.requestPreview(font) }
    }

    /// Pangrams: every letter of the Russian and the English alphabet.
    static let russianSample = "Съешь же ещё этих мягких французских булок, да выпей чаю"
    static let englishSample = "The quick brown fox jumps over the lazy dog"

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
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 4)
                .frame(height: 28)
        } else {
            Button(L("Применить")) {
                model.setStyle(\.fontFamily, \.fontFamily, family)
            }
            .buttonStyle(TintedCapsuleButtonStyle())
            .help(L("Поставить этот шрифт: %@", "\(model.scopeTitle.lowercased())"))
        }
    }
}
