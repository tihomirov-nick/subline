import Foundation
import SubtitsCore

/// Presets are kept in ~/Library/Application Support/Subtits/presets.json
enum PresetStore {
    static func load() -> [SubtitlePreset] {
        guard let data = try? Data(contentsOf: AppPaths.presetsFile),
              let presets = try? JSONDecoder().decode([SubtitlePreset].self, from: data),
              !presets.isEmpty else {
            return SubtitlePreset.builtIn
        }
        return presets
    }

    static func save(_ presets: [SubtitlePreset]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(presets) else { return }
        try? data.write(to: AppPaths.presetsFile, options: .atomic)
    }

    /// Writes presets to a file that can be sent to another Mac.
    static func export(_ presets: [SubtitlePreset], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: url, options: .atomic)
    }

    /// Reads a preset file (one preset or a list). Imported presets get new identifiers.
    static func importPresets(from url: URL) throws -> [SubtitlePreset] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var presets: [SubtitlePreset]
        if let list = try? decoder.decode([SubtitlePreset].self, from: data) {
            presets = list
        } else {
            presets = [try decoder.decode(SubtitlePreset.self, from: data)]
        }
        for i in presets.indices { presets[i].id = UUID() }
        return presets
    }
}

/// Recognized transcripts and edited subtitles are cached per media file, so reopening a video is instant.
enum TranscriptCache {
    struct Entry: Codable {
        var transcript: Transcript
        var cues: [Cue]
        var edited: Bool
        var layoutKey: String
        var modelID: String
        var groups: [SubtitleGroup]?
    }

    static func key(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let source = "\(url.standardizedFileURL.path)|\(size)|\(Int(modified))"
        return sha256Hex(Data(source.utf8))
    }

    static func load(for url: URL) -> Entry? {
        guard let key = key(for: url),
              let data = try? Data(contentsOf: AppPaths.cacheDir.appendingPathComponent("\(key).json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Entry.self, from: data)
    }

    static func save(_ entry: Entry, for url: URL) {
        guard let key = key(for: url) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: AppPaths.cacheDir.appendingPathComponent("\(key).json"), options: .atomic)
    }
}
