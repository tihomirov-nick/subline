import Foundation

/// A failure told for the person: the title says what happened, the message says why and what to do, and the technical
/// text (ffmpeg's own lines, the system error) waits under «Подробнее».
public struct Problem: Equatable, Sendable {
    public var title: String
    public var message: String
    public var details: String?

    public init(title: String, message: String, details: String? = nil) {
        self.title = title
        self.message = message
        self.details = details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Why a file could not be read or written, as far as the error tells.
    public enum Cause: Equatable, Sendable {
        case noPermission, noSpace, readOnly, notFound, damaged, picture, unknown
    }

    /// The cause and the technical text of an error from ffmpeg or from the file system.
    public static func cause(of error: Error) -> (cause: Cause, details: String?) {
        switch error {
        case MediaError.image:
            return (.picture, nil)
        case MediaError.failed(let log), MediaError.unreadable(let log):
            return (cause(inLog: log), log)
        default:
            break
        }
        let ns = error as NSError
        let details = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        if ns.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: ns.code) {
            case .fileWriteNoPermission, .fileReadNoPermission: return (.noPermission, details)
            case .fileWriteOutOfSpace: return (.noSpace, details)
            case .fileWriteVolumeReadOnly: return (.readOnly, details)
            case .fileNoSuchFile, .fileReadNoSuchFile: return (.notFound, details)
            case .fileReadCorruptFile: return (.damaged, details)
            default: break
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return (cause(posix: underlying.code), details)
            }
        }
        if ns.domain == NSPOSIXErrorDomain { return (cause(posix: ns.code), details) }
        return (.unknown, details)
    }

    static func cause(posix code: Int) -> Cause {
        switch code {
        case Int(EACCES), Int(EPERM): return .noPermission
        case Int(ENOSPC), Int(EDQUOT): return .noSpace
        case Int(EROFS): return .readOnly
        case Int(ENOENT): return .notFound
        default: return .unknown
        }
    }

    /// Reads ffmpeg's lines for the usual reasons.
    public static func cause(inLog log: String) -> Cause {
        let text = log.lowercased()
        if text.contains("no space left") || text.contains("disk quota exceeded") { return .noSpace }
        if text.contains("read-only file system") { return .readOnly }
        if text.contains("permission denied") || text.contains("operation not permitted") { return .noPermission }
        if text.contains("no such file or directory") { return .notFound }
        let damaged = ["invalid data found", "moov atom not found", "could not find codec parameters", "error while decoding",
                       "corrupt", "truncat", "end of file", "invalid nal", "no frame!", "header missing"]
        if damaged.contains(where: text.contains) { return .damaged }
        return .unknown
    }

    // MARK: - Situations

    /// The bundled ffmpeg is gone: nothing works until Subline is installed again.
    static func brokenInstall(_ error: Error) -> Problem? {
        guard case MediaError.ffmpegNotFound = error else { return nil }
        return Problem(title: L("Не хватает части Subline"), message: error.localizedDescription)
    }

    /// A video or audio file did not open.
    public static func opening(_ error: Error, file: URL) -> Problem {
        if let broken = brokenInstall(error) { return broken }
        let (cause, details) = cause(of: error)
        let name = file.lastPathComponent
        switch cause {
        case .picture:
            return Problem(title: L("Картинки Subline не открывает"),
                           message: L("Субтитры делаются к видео и аудио. Откройте видео- или аудиофайл"))
        case .noPermission:
            return Problem(title: L("Нет доступа к файлу"),
                           message: L("macOS не даёт Subline прочитать «%@». Скопируйте файл в свою папку, например в «Фильмы», и откройте копию", name),
                           details: details)
        case .notFound:
            return Problem(title: L("Файл не найден"),
                           message: L("Файла «%@» больше нет на прежнем месте. Возможно, его переместили, переименовали или отключили диск", name),
                           details: details)
        case .damaged:
            return Problem(title: L("Файл не открылся"),
                           message: L("Похоже, «%@» повреждён или в нём нет ни видео, ни звука. Проверьте, открывается ли он в другом плеере", name),
                           details: details)
        default:
            return Problem(title: L("Файл не открылся"),
                           message: L("Subline не смог прочитать «%@» как видео или аудио. Технические подробности есть под кнопкой «Подробнее»", name),
                           details: details ?? error.localizedDescription)
        }
    }

    /// The video with subtitles was not written.
    public static func exporting(_ error: Error, output: URL, source: URL?) -> Problem {
        if let broken = brokenInstall(error) { return broken }
        let (cause, details) = cause(of: error)
        let folder = output.deletingLastPathComponent()
        switch cause {
        case .noPermission:
            return Problem(title: L("Нет доступа к папке"),
                           message: L("В папку «%@» Subline записывать не может. Выберите другую, например «Фильмы» или «Рабочий стол»", folder.lastPathComponent),
                           details: details)
        case .noSpace:
            return Problem(title: L("На диске не хватило места"),
                           message: L("Видео не поместилось на «%@». Освободите место или выберите папку на другом диске", volumeName(of: folder)),
                           details: details)
        case .readOnly:
            return Problem(title: L("Диск только для чтения"),
                           message: L("На «%@» ничего нельзя записать. Выберите папку на другом диске", volumeName(of: folder)),
                           details: details)
        case .notFound:
            if let source, !FileManager.default.fileExists(atPath: source.path) {
                return Problem(title: L("Исходное видео пропало"),
                               message: L("Файла «%@» больше нет на прежнем месте. Верните его или откройте снова, затем повторите экспорт", source.lastPathComponent),
                               details: details)
            }
            return Problem(title: L("Папка пропала"),
                           message: L("Папки «%@» больше нет. Выберите другую и повторите экспорт", folder.lastPathComponent),
                           details: details)
        case .damaged:
            return Problem(title: L("Экспорт не удался"),
                           message: L("Часть исходного видео не читается, возможно, файл повреждён. Попробуйте другой формат или пересохраните видео в другом приложении"),
                           details: details)
        default:
            return Problem(title: L("Экспорт не удался"),
                           message: L("Видео не сохранилось. Попробуйте ещё раз или выберите другой формат. Технические подробности есть под кнопкой «Подробнее»"),
                           details: details ?? error.localizedDescription)
        }
    }

    /// A small file (SRT, presets) was not written.
    public static func saving(_ error: Error, output: URL) -> Problem {
        let (cause, details) = cause(of: error)
        let folder = output.deletingLastPathComponent()
        switch cause {
        case .noPermission:
            return Problem(title: L("Нет доступа к папке"),
                           message: L("В папку «%@» Subline записывать не может. Выберите другую, например «Документы» или «Рабочий стол»", folder.lastPathComponent),
                           details: details)
        case .noSpace:
            return Problem(title: L("На диске не хватило места"),
                           message: L("Освободите место на «%@» или выберите папку на другом диске", volumeName(of: folder)),
                           details: details)
        case .readOnly:
            return Problem(title: L("Диск только для чтения"),
                           message: L("На «%@» ничего нельзя записать. Выберите папку на другом диске", volumeName(of: folder)),
                           details: details)
        default:
            return Problem(title: L("Файл не сохранился"),
                           message: L("«%@» не записался. Попробуйте ещё раз или выберите другую папку", output.lastPathComponent),
                           details: details ?? error.localizedDescription)
        }
    }

    /// Speech recognition broke off.
    public static func recognizing(_ error: Error, file: URL?) -> Problem {
        if let whisper = error as? WhisperError {
            switch whisper {
            case .modelNotFound, .modelLoadFailed:
                return Problem(title: L("Модель не загрузилась"), message: whisper.localizedDescription)
            default:
                return Problem(title: L("Распознавание не удалось"), message: whisper.localizedDescription)
            }
        }
        if let broken = brokenInstall(error) { return broken }
        let (cause, details) = cause(of: error)
        switch cause {
        case .notFound:
            let name = file?.lastPathComponent ?? ""
            return Problem(title: L("Файл не найден"),
                           message: L("Файла «%@» больше нет на прежнем месте. Возможно, его переместили, переименовали или отключили диск", name),
                           details: details)
        case .noPermission:
            return Problem(title: L("Нет доступа к файлу"),
                           message: L("macOS не даёт Subline прочитать «%@». Скопируйте файл в свою папку, например в «Фильмы», и откройте копию", file?.lastPathComponent ?? ""),
                           details: details)
        case .noSpace:
            return Problem(title: L("На диске не хватило места"),
                           message: L("Для распознавания Subline ненадолго сохраняет звук на диск, а места не осталось. Освободите место и попробуйте ещё раз"),
                           details: details)
        case .damaged:
            return Problem(title: L("Звук не читается"),
                           message: L("Звуковая дорожка повреждена или записана в необычном виде. Попробуйте пересохранить видео в другом приложении"),
                           details: details)
        default:
            if case MediaError.noAudio = error {
                return Problem(title: L("В файле нет звука"), message: error.localizedDescription)
            }
            return Problem(title: L("Распознавание не удалось"),
                           message: L("Звук из файла не извлёкся. Попробуйте ещё раз. Технические подробности есть под кнопкой «Подробнее»"),
                           details: details ?? error.localizedDescription)
        }
    }

    /// The disk a folder is on, by the name Finder shows.
    static func volumeName(of folder: URL) -> String {
        (try? folder.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? folder.lastPathComponent
    }
}
