import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SubtitsCore

/// Downloading and choosing Whisper models. Rows read like an App Store list: icon, name and details,
/// and the action as a capsule on the right.
struct ModelManagerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BarredScroll {
            SheetHeader(symbol: "waveform", color: .purple,
                        title: L("Модели распознавания Whisper"),
                        subtitle: L("Модели скачиваются один раз и хранятся на этом Mac, распознавание работает без интернета. Для русского языка лучше всего подходят Large v3 Turbo и модели, дообученные на русской речи.")) {
                Button(L("Готово")) { dismiss() }
                    .glassProminentButton()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ModelCatalog.models) { info in
                    ModelRow(info: info)
                }
                if !modelStore.customModels.isEmpty {
                    SectionHeader(L("Свои модели"))
                        .padding(.top, 10)
                    ForEach(modelStore.customModels, id: \.self) { url in
                        CustomModelRow(url: url)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 6)
        } footer: {
            HStack(spacing: 8) {
                Button {
                    addCustomModel()
                } label: {
                    Label(L("Добавить свою модель (.bin)…"), systemImage: "plus")
                }
                .help(L("Любая модель Whisper в формате ggml для whisper.cpp"))
                Button {
                    NSWorkspace.shared.open(AppPaths.modelsDir)
                } label: {
                    Label(L("Папка моделей"), systemImage: "folder")
                }
                Spacer()
                if let error = modelStore.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .trailing)
                }
            }
            .glassButton()
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 720, height: 620)
        .background(Color.groupedBackground)
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

/// Capsule action in the App Store manner: tinted fill, bold accent title.
struct TintedCapsuleButtonStyle: ButtonStyle {
    var color: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        TintedCapsuleBody(configuration: configuration, color: color)
    }

    private struct TintedCapsuleBody: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.26 : 0.15)))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
        }
    }
}

/// Round icon button (delete, cancel) with a quiet fill.
struct RoundIconButtonStyle: ButtonStyle {
    var color: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

private struct ModelRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    let info: WhisperModelInfo

    var body: some View {
        let installed = modelStore.installed.contains(info.id)
        let download = modelStore.downloads[info.id]
        let selected = model.modelID == info.id
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: "waveform", color: tileColor, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(info.name)
                        .font(.system(size: 14, weight: .semibold))
                    if info.recommended { Badge(text: L("Рекомендуется")) }
                    if info.russianTuned { Badge(text: L("Русский"), color: .purple) }
                    if selected && installed { Badge(text: L("Выбрана"), color: .green) }
                }
                Text(info.details)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(info.sizeText)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            if let download {
                VStack(alignment: .trailing, spacing: 5) {
                    ProgressView(value: download.fraction)
                        .frame(width: 170)
                    Text(progressText(download))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(download.retryMessage == nil ? Color.secondary : Color.orange)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
                if !download.verifying {
                    Button {
                        modelStore.cancelDownload(info.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(RoundIconButtonStyle())
                    .help(L("Отменить загрузку"))
                }
            } else if installed {
                if !selected {
                    Button(L("Выбрать")) { model.modelID = info.id }
                        .buttonStyle(TintedCapsuleButtonStyle())
                }
                Button {
                    if selected { model.modelID = "" }
                    modelStore.delete(info)
                    model.ensureValidModelSelection()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(RoundIconButtonStyle())
                .help(L("Удалить модель с диска"))
            } else {
                Button {
                    modelStore.download(info)
                } label: {
                    Label(L("Скачать"), systemImage: "arrow.down")
                }
                .buttonStyle(TintedCapsuleButtonStyle())
            }
        }
        .padding(14)
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected && installed ? 2 : 0)
        )
    }

    private var tileColor: Color {
        if info.russianTuned { return .purple }
        if info.recommended { return .blue }
        return Color(nsColor: .systemGray)
    }

    private func progressText(_ state: ModelStore.DownloadState) -> String {
        if state.verifying { return L("Проверка файла…") }
        if let retry = state.retryMessage { return retry }
        let received = formatBytes(state.received)
        let total = formatBytes(state.total)
        var text = L("%@ из %@", "\(received)", "\(total)")
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
        HStack(spacing: 14) {
            IconTile(symbol: "shippingbox.fill", color: .teal, size: 38)
            Text(url.lastPathComponent)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if selected { Badge(text: L("Выбрана"), color: .green) }
            Spacer()
            if !selected {
                Button(L("Выбрать")) { model.modelID = id }
                    .buttonStyle(TintedCapsuleButtonStyle())
            }
            Button {
                if selected { model.modelID = "" }
                modelStore.deleteCustom(url)
                model.ensureValidModelSelection()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(RoundIconButtonStyle())
            .help(L("Удалить модель с диска"))
        }
        .padding(14)
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
        )
    }
}
