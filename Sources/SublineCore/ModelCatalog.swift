import Foundation

/// A Whisper model (ggml format for whisper.cpp) that can be downloaded in the app.
public struct WhisperModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let details: String
    /// One short line for the list; `details` goes into its tooltip.
    public let summary: String
    public let fileName: String
    public let url: URL
    public let sizeBytes: Int64
    public let sha256: String?
    public let recommended: Bool
    public let russianTuned: Bool

    public var localURL: URL { AppPaths.modelsDir.appendingPathComponent(fileName) }

    public var isDownloaded: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return sizeBytes <= 0 || size.int64Value == sizeBytes
    }

    public var sizeText: String { formatBytes(sizeBytes) }
}

public enum ModelCatalog {
    private static let whisperCpp = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    public static let models: [WhisperModelInfo] = [
        WhisperModelInfo(
            id: "large-v3-turbo-q8_0", name: "Whisper Large v3 Turbo",
            details: L("Быстрая и точная, понимает русский и еще около 100 языков. Подходит для большинства видео"),
            summary: L("Быстрая и точная, около 100 языков"),
            fileName: "ggml-large-v3-turbo-q8_0.bin", url: URL(string: whisperCpp + "ggml-large-v3-turbo-q8_0.bin")!,
            sizeBytes: 874_188_075, sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
            recommended: true, russianTuned: false
        ),
        WhisperModelInfo(
            id: "large-v3-russian-q5_0", name: "Whisper Large v3 Russian",
            details: L("Дообучена на русской речи (antony66), реже ошибается в словах и пишет «ё». Работает примерно в 3 раза медленнее Turbo"),
            summary: L("Дообучена на русской речи, медленнее Turbo"),
            fileName: "ggml-large-v3-russian-q5_0.bin",
            url: URL(string: "https://huggingface.co/Pomni/whisper-large-v3-russian-ggml-allquants/resolve/main/ggml-large-v3-russian-q5_0.bin")!,
            sizeBytes: 1_081_140_203, sha256: "21444001e24953d2d4da409f4ef6a7f22daf961cbb6f453eb7fbb1cd63337798",
            recommended: false, russianTuned: true
        ),
        WhisperModelInfo(
            id: "large-v3-russian-podlodka-q5_0", name: "Whisper Large v3 Russian Podlodka",
            details: L("Дообучена на русских подкастах, подходит для интервью, влогов и другой живой речи. Работает примерно в 3 раза медленнее Turbo"),
            summary: L("Для интервью и влогов на русском, медленнее Turbo"),
            fileName: "ggml-large-v3-russian-ties-podlodka-v1.2-q5_0.bin",
            url: URL(string: "https://huggingface.co/Pomni/whisper-large-v3-russian-ties-podlodka-v1.2-ggml-allquants/resolve/main/ggml-large-v3-russian-ties-podlodka-v1.2-q5_0.bin")!,
            sizeBytes: 1_081_140_203, sha256: "1ba1effb19430fcdb02c287c41f1a08acd79563e20eb8361185ea1c1f97b2fe3",
            recommended: false, russianTuned: true
        ),
        WhisperModelInfo(
            id: "large-v3-q5_0", name: "Whisper Large v3",
            details: L("Самая точная из стандартных моделей Whisper, но медленная"),
            summary: L("Самая точная из стандартных, но медленная"),
            fileName: "ggml-large-v3-q5_0.bin", url: URL(string: whisperCpp + "ggml-large-v3-q5_0.bin")!,
            sizeBytes: 1_081_140_203, sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
            recommended: false, russianTuned: false
        ),
        WhisperModelInfo(
            id: "large-v3-turbo-q5_0", name: L("Whisper Large v3 Turbo (легкая)"),
            details: L("Сжатая версия Turbo. Качество почти то же, а файл меньше"),
            summary: L("Сжатая Turbo, файл меньше"),
            fileName: "ggml-large-v3-turbo-q5_0.bin", url: URL(string: whisperCpp + "ggml-large-v3-turbo-q5_0.bin")!,
            sizeBytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            recommended: false, russianTuned: false
        ),
        WhisperModelInfo(
            id: "medium-q5_0", name: "Whisper Medium",
            details: L("Модель среднего размера для слабых или старых Mac"),
            summary: L("Для слабых или старых Mac"),
            fileName: "ggml-medium-q5_0.bin", url: URL(string: whisperCpp + "ggml-medium-q5_0.bin")!,
            sizeBytes: 539_212_467, sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
            recommended: false, russianTuned: false
        ),
        WhisperModelInfo(
            id: "small", name: "Whisper Small",
            details: L("Быстрая, но ошибается заметно чаще"),
            summary: L("Быстрая, но ошибается чаще"),
            fileName: "ggml-small.bin", url: URL(string: whisperCpp + "ggml-small.bin")!,
            sizeBytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            recommended: false, russianTuned: false
        ),
        WhisperModelInfo(
            id: "base", name: "Whisper Base",
            details: L("Очень быстрая, годится для черновика"),
            summary: L("Очень быстрая, для черновика"),
            fileName: "ggml-base.bin", url: URL(string: whisperCpp + "ggml-base.bin")!,
            sizeBytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            recommended: false, russianTuned: false
        ),
    ]

    public static var recommended: WhisperModelInfo { models.first { $0.recommended }! }

    public static func model(id: String) -> WhisperModelInfo? { models.first { $0.id == id } }

    /// Model files in the models folder that are not part of the catalog (added by the user).
    public static func customModelFiles() -> [URL] {
        let known = Set(models.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.modelsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "bin" && !known.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
