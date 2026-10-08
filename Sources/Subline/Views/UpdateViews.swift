import SwiftUI
import SublineCore

// MARK: - Texts

/// The updater (Updater.swift) is the same file in every app of the family and has no texts: Subline names its states.
extension Updater.Failure {
    /// One line under the update.
    var text: String {
        switch self {
        case .offline: return L("Нет связи с GitHub")
        case .rateLimited: return L("GitHub ограничил запросы")
        case .noInstaller: return L("В релизе нет установщика")
        case .download: return L("Загрузка прервалась")
        case .damaged: return L("Установщик повреждён")
        case .notTrusted: return L("Подпись не совпадает")
        case .cannotReplace: return L("Не удалось заменить Subline")
        }
    }

    /// Why, and what to do: in the tooltip.
    var help: String {
        switch self {
        case .offline: return L("Проверьте интернет и попробуйте ещё раз")
        case .rateLimited: return L("С этого адреса было слишком много запросов к GitHub. Попробуйте через час")
        case .noInstaller: return L("К новой версии не приложен DMG. Скачайте его позже со страницы релиза")
        case .download: return L("Загрузка не закончилась. Попробуйте ещё раз или скачайте DMG со страницы релиза")
        case .damaged: return L("Скачанный DMG не совпадает с релизом или в нём нет новой версии Subline")
        case .notTrusted:
            return L("Новая версия подписана не так, как установленная, поэтому сама она не ставится. Скачайте DMG со страницы релиза и перетащите Subline в папку «Программы»")
        case .cannotReplace:
            return L("Subline открыт с диска только для чтения или из папки без права записи. Перетащите Subline из открытого DMG в папку «Программы»")
        }
    }
}

extension Updater {
    /// The status in Settings, next to the version.
    var statusText: String {
        switch state {
        case .idle: return isDevelopmentBuild ? L("Сборка для разработки") : ""
        case .checking: return L("Проверяю…")
        case .upToDate: return L("Последняя версия")
        case .available(let release): return L("Доступна %@", "\(release.version)")
        case .downloading(_, let progress): return L("Загрузка %@%%", "\(Int(progress * 100))")
        case .installing: return L("Устанавливаю…")
        case .failed(let failure, _): return failure.text
        }
    }

    var statusHelp: String {
        switch state {
        case .failed(let failure, _): return failure.help
        default:
            return isDevelopmentBuild ? L("Сборка из исходников сама не проверяет обновления и не заменяет себя")
                                      : L("Новые версии Subline берутся из релизов на GitHub")
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}

/// The release text without Markdown.
enum ReleaseNotes {
    /// What is new in two lines: the first points of the list, or the first paragraph when there is no list.
    static func summary(_ notes: String) -> String {
        let lines = notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let points = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("+ ") }
        let chosen = points.isEmpty ? Array(lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.prefix(1)) : Array(points.prefix(2))
        return chosen.map(plain).joined(separator: "\n")
    }

    /// The whole text for the tooltip.
    static func full(_ notes: String) -> String {
        notes.split(separator: "\n").map { plain($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func plain(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, "#-*+>".contains(first) { text = text.dropFirst().drop { $0 == " " } }
        return ["**", "__", "`"].reduce(String(text)) { $0.replacingOccurrences(of: $1, with: "") }
    }
}

// MARK: - The card in the window

/// The update at the bottom of the subtitles block: what is new and Update, Later, Skip; the progress with Cancel
/// while it downloads; a short reason and the release page when it fails. Updating restarts Subline, so it waits
/// until recognition and export are over.
struct UpdateBanner: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            details
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .animation(Motion.animation(Motion.quick, reduceMotion: reduceMotion), value: kind)
    }

    private var header: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
            }
            .help(titleHelp)
            Spacer(minLength: 4)
            switch updater.state {
            case .upToDate, .failed:
                IconButton(symbol: "xmark", help: L("Скрыть"), size: 22, filled: false) { updater.dismiss() }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        switch updater.state {
        case .available(let release):
            let summary = ReleaseNotes.summary(release.notes)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(ReleaseNotes.full(release.notes))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    updateButton
                    laterButton
                    skipButton(release)
                }
                VStack(spacing: 6) {
                    updateButton
                    HStack(spacing: 6) {
                        laterButton
                        skipButton(release)
                    }
                }
            }
            .controlSize(.small)
        case .downloading(_, let progress):
            HStack(spacing: 8) {
                ProgressLine(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button(L("Отменить")) { updater.cancel() }
                    .appButton(.secondary)
                    .controlSize(.small)
                    .fixedSize()
            }
        case .installing, .checking:
            ProgressLine(value: nil)
        case .failed(let failure, _):
            Button(failure == .cannotReplace ? L("Открыть DMG") : L("Страница релиза")) { updater.openReleasePage() }
                .appButton(.secondary)
                .controlSize(.small)
                .help(failure == .cannotReplace ? L("Открыть скачанный DMG в Finder") : L("Открыть релиз на GitHub"))
        case .idle, .upToDate:
            EmptyView()
        }
    }

    private var updateButton: some View {
        Button {
            updater.install()
        } label: {
            Text(L("Обновить"))
                .frame(maxWidth: .infinity)
        }
        .appButton(.primary)
        .disabled(model.isBusy || updater.isDevelopmentBuild)
        .help(updateHelp)
    }

    private var laterButton: some View {
        Button(L("Позже")) { updater.dismiss() }
            .appButton(.secondary)
            .fixedSize()
            .help(L("Напомнить при следующей проверке"))
    }

    private func skipButton(_ release: Updater.Release) -> some View {
        Button(L("Пропустить")) { updater.skip() }
            .appButton(.secondary)
            .fixedSize()
            .help(L("Больше не предлагать версию %@", "\(release.version)"))
    }

    private var updateHelp: String {
        if updater.isDevelopmentBuild { return L("Сборка из исходников не заменяет себя. Установите Subline из DMG") }
        if model.isBusy { return L("Обновление перезапустит Subline, поэтому оно станет доступно, когда закончится распознавание или экспорт") }
        return L("Скачать новую версию, установить её и перезапустить Subline")
    }

    private var icon: some View {
        let failed: Bool = { if case .failed = updater.state { return true }; return false }()
        return Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(failed ? Palette.attention : (updater.state == .checking ? Color.white : Color.black))
            .frame(width: 26, height: 26)
            .background(Circle().fill(failed ? Palette.attention.opacity(0.2) : (updater.state == .checking ? Palette.fill : Brand.mark)))
    }

    private var symbol: String {
        switch updater.state {
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark"
        case .failed: return "exclamationmark"
        default: return "arrow.down"
        }
    }

    private var title: String {
        switch updater.state {
        case .idle, .checking: return L("Проверяю обновления…")
        case .upToDate: return L("Установлена последняя версия")
        case .available(let release): return L("Доступна версия %@", "\(release.version)")
        case .downloading(let release, _): return L("Загружаю версию %@", "\(release.version)")
        case .installing(let release): return L("Устанавливаю версию %@", "\(release.version)")
        case .failed(let failure, _): return failure.text
        }
    }

    private var subtitle: String? {
        switch updater.state {
        case .upToDate: return "Subline \(updater.currentVersion)"
        case .installing: return L("Subline перезапустится сам")
        case .failed(_, let release?): return L("Версия %@", "\(release.version)")
        default: return nil
        }
    }

    private var titleHelp: String {
        switch updater.state {
        case .failed(let failure, _): return failure.help
        case .available(let release), .downloading(let release, _), .installing(let release): return release.title
        default: return ""
        }
    }

    /// Changes the animation follows: one per kind of state, not per percent.
    private var kind: Int {
        switch updater.state {
        case .idle: return 0
        case .checking: return 1
        case .upToDate: return 2
        case .available: return 3
        case .downloading: return 4
        case .installing: return 5
        case .failed: return 6
        }
    }
}
