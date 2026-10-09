import SwiftUI
import AppKit
import SublineCore

/// Help → Subline Help: how the app works, in a few short sections, without leaving the window.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L("Как работать с Subline")) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(L("Три шага"), [
                        L("Скачайте модель распознавания. Это делается один раз, дальше всё работает без интернета."),
                        L("Откройте видео. Перетащите файл в окно или нажмите ⌘O. Если включено «Распознавать сразу», речь распознаётся сама."),
                        L("Поправьте субтитры и нажмите «Экспорт». Видео с субтитрами сохранится туда, куда вы укажете."),
                    ], numbered: true)
                    section(L("Текст субтитров"), [
                        L("Щёлкните текст субтитра в списке и печатайте. Return или Esc заканчивают правку, Tab переходит к следующему субтитру."),
                        L("⌘B делит субтитр там, где стоит курсор в тексте. ⌥⌘↑ и ⌥⌘↓ переносят крайнее слово в соседний субтитр."),
                        L("Всё остальное есть в меню «Субтитры» и в меню «…» у каждой строки. ⌘Z отменяет правку целиком."),
                    ])
                    section(L("Видео"), [
                        L("Пробел запускает и останавливает видео, ← и → шагают по кадрам, ↑ и ↓ переходят между субтитрами."),
                        L("Щелчок по субтитру в списке переводит видео к его началу."),
                    ])
                    section(L("Стиль"), [
                        L("Вверху справа выбирается, что меняется: «Все» меняет пресет целиком, «Группа» и «Субтитр» меняют только выбранные субтитры, «Слова» меняют слова, выбранные щелчком на видео."),
                        L("Текст на видео можно двигать мышью. До распознавания там виден пример текста, по нему удобно настроить пресет."),
                    ])
                    section(L("Сохранение"), [
                        L("Субтитры и правки сохраняются сами. Если закрыть Subline, при следующем запуске видео откроется вместе с ними."),
                        L("Последние файлы есть в меню «Файл» → «Открыть недавние»."),
                    ])
                }
                .padding(.horizontal, Metrics.inset + 2)
                .padding(.bottom, Metrics.inset + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 560)
        .background(Palette.block)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func section(_ title: String, _ points: [String], numbered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(numbered ? "\(index + 1)." : "•")
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.secondary)
                            .frame(width: 16, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(point)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

/// The technical text of a failure (ffmpeg's lines, the system error), to read or to copy for a bug report.
struct ProblemDetailsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L("Подробности ошибки")) {
                Button(copied ? L("Скопировано") : L("Скопировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .appButton(.secondary)
            } done: {
                dismiss()
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .card()
            .padding(.horizontal, Metrics.inset + 2)
            .padding(.bottom, Metrics.inset + 2)
        }
        .frame(width: 560, height: 320)
        .background(Palette.block)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
