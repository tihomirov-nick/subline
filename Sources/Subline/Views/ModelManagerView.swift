import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SublineCore

/// Downloading and choosing Whisper models: one card with a row per model, the action on the right of each.
struct ModelManagerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L("Модели распознавания"),
                        help: L("Модели скачиваются один раз и хранятся на этом Mac, распознавание работает без интернета. Для русской речи лучше всего подходят Large v3 Turbo и модели, дообученные на русском")) {
                dismiss()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 0) {
                        ForEach(Array(ModelCatalog.models.enumerated()), id: \.element.id) { index, info in
                            if index > 0 { Separator() }
                            ModelRow(info: info)
                        }
                    }
                    .card()
                    if !modelStore.customModels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(L("Свои модели"))
                            VStack(spacing: 0) {
                                ForEach(Array(modelStore.customModels.enumerated()), id: \.element) { index, url in
                                    if index > 0 { Separator() }
                                    CustomModelRow(url: url)
                                }
                            }
                            .card()
                        }
                    }
                }
                .padding(.horizontal, Metrics.inset + 2)
                .padding(.bottom, Metrics.inset)
            }
            Separator(leading: 0)
            HStack(spacing: 8) {
                Button(L("Своя модель…")) {
                    addCustomModel()
                }
                .help(L("Любая модель Whisper в формате ggml для whisper.cpp (.bin)"))
                Button(L("Папка моделей")) {
                    NSWorkspace.shared.open(AppPaths.modelsDir)
                }
                Spacer(minLength: 8)
                if let error = modelStore.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.danger)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(error)
                }
            }
            .appButton(.secondary)
            .controlSize(.small)
            .padding(.horizontal, Metrics.inset + 2)
            .padding(.vertical, Metrics.inset)
        }
        .frame(width: 620, height: 560)
        .background(Palette.block)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { modelStore.refresh() }
    }

    private func addCustomModel() {
        let panel = NSOpenPanel()
        panel.title = L("Выберите модель Whisper (ggml .bin)")
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelStore.importModel(from: url)
    }
}

/// The title of a sheet with «Готово» on the right; what the sheet is for is in the tooltip of the title.
struct SheetHeader<Accessory: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var accessory: Accessory
    let done: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .help(help ?? "")
            Spacer(minLength: 8)
            accessory
            Button(L("Готово"), action: done)
                .appButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Metrics.inset + 2)
        .padding(.top, Metrics.inset + 2)
        .padding(.bottom, 10)
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(title: String, help: String? = nil, done: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.accessory = EmptyView()
        self.done = done
    }
}

private struct ModelRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    let info: WhisperModelInfo

    var body: some View {
        let installed = modelStore.installed.contains(info.id)
        let download = modelStore.downloads[info.id]
        let selected = model.modelID == info.id && installed
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark" : "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? Brand.mark : Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if info.recommended { Badge(text: L("Рекомендуется")) }
                    if info.russianTuned { Badge(text: L("Русский"), color: Color(red: 0.75, green: 0.6, blue: 1)) }
                }
                Text(info.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            .help(info.details)
            Spacer(minLength: 8)
            if let download {
                VStack(alignment: .trailing, spacing: 5) {
                    ProgressLine(value: download.verifying ? nil : download.fraction)
                        .frame(width: 120)
                    Text(progressText(download))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(download.retryMessage == nil ? Palette.secondary : Palette.attention)
                        .lineLimit(1)
                        .help(download.retryMessage ?? "")
                }
                if !download.verifying {
                    IconButton(symbol: "xmark", help: L("Отменить загрузку"), size: 24) {
                        modelStore.cancelDownload(info.id)
                    }
                }
            } else {
                Text(info.sizeText)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                if installed {
                    if !selected {
                        Button(L("Выбрать")) { model.modelID = info.id }
                            .appButton(.secondary)
                            .controlSize(.small)
                            .fixedSize()
                    }
                    IconButton(symbol: "trash", help: L("Удалить модель с диска"), size: 24) {
                        if model.modelID == info.id { model.modelID = "" }
                        modelStore.delete(info)
                        model.ensureValidModelSelection()
                    }
                } else {
                    Button(L("Скачать")) { modelStore.download(info) }
                        .appButton(.primary)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
    }

    private func progressText(_ state: ModelStore.DownloadState) -> String {
        if state.verifying { return L("Проверяю файл…") }
        if let retry = state.retryMessage { return retry }
        var text = L("%@ из %@", "\(formatBytes(state.received))", "\(formatBytes(state.total))")
        if state.bytesPerSecond > 0 {
            text += " · " + formatBytes(Int64(state.bytesPerSecond)) + L("/с")
        }
        return text
    }
}

private struct CustomModelRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    let url: URL

    var body: some View {
        let id = "custom:" + url.lastPathComponent
        let selected = model.modelID == id
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark" : "shippingbox.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? Brand.mark : Color.white.opacity(0.12)))
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !selected {
                Button(L("Выбрать")) { model.modelID = id }
                    .appButton(.secondary)
                    .controlSize(.small)
                    .fixedSize()
            }
            IconButton(symbol: "trash", help: L("Удалить модель с диска"), size: 24) {
                if selected { model.modelID = "" }
                modelStore.deleteCustom(url)
                model.ensureValidModelSelection()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
    }
}
