import SwiftUI
import SubtitsCore

/// Settings (⌘,): interface language.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var modelStore: ModelStore
    @EnvironmentObject var fontStore: FontStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var language = Localization.selected
    @State private var relaunchFailed = false

    var body: some View {
        Form {
            Section {
                Picker(L("Язык интерфейса"), selection: $language) {
                    ForEach(AppLanguage.allCases) { item in
                        Text(title(of: item)).tag(item)
                    }
                }
            } footer: {
                Text(L("В режиме «Автоматически» Subtits работает на русском, если русский есть среди языков macOS, а иначе на английском."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if language.code != Localization.current {
                Section {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Язык сменится после перезапуска"))
                            Text(relaunchNote)
                                .font(.system(size: 11))
                                .foregroundStyle(relaunchFailed ? Color.red : Color.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(L("Перезапустить")) {
                            relaunchFailed = false
                            AppDelegate.relaunch(model) { relaunchFailed = true }
                        }
                        .disabled(busyReason != nil)
                    }
                }
                .transition(.opacity)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: language)
        .onChange(of: language) { newValue in
            Localization.select(newValue)
        }
    }

    /// "Automatic" also shows which language it picks on this Mac.
    private func title(of item: AppLanguage) -> String {
        guard item == .automatic else { return item.title }
        return "\(item.title) (\(item.code == "ru" ? L("русский") : L("английский")))"
    }

    private var busyReason: String? {
        if model.isBusy { return L("Дождитесь окончания распознавания или экспорта.") }
        if !modelStore.downloads.isEmpty || !fontStore.installing.isEmpty {
            return L("Дождитесь окончания загрузки.")
        }
        return nil
    }

    private var relaunchNote: String {
        if relaunchFailed { return L("Не получилось перезапустить. Закройте Subtits и откройте снова.") }
        return busyReason ?? L("Открытое видео и правки сохранятся.")
    }
}
