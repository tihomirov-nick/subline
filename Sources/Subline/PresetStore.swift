import Foundation
import SublineCore

/// Presets are kept in ~/Library/Application Support/Subline/presets.json
enum PresetStore {
    static func load() -> [SubtitlePreset] {
        guard let data = try? Data(contentsOf: AppPaths.presetsFile),
              let presets = try? JSONDecoder().decode([SubtitlePreset].self, from: data),
              !presets.isEmpty else {
            let builtIn = SubtitlePreset.builtIn
            // Written at once: built-in presets get new identifiers on every launch otherwise, and the chosen preset
            // (and the one a video was styled with) would not be found after a restart. A damaged file stays as it is.
            if !FileManager.default.fileExists(atPath: AppPaths.presetsFile.path) { save(builtIn) }
            return builtIn
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

/// Recognized transcripts and edited subtitles are cached per media file, so reopening a video is instant. The key is
/// the content of the file (its size and its first and last megabyte), so the work comes back after the file was moved,
/// renamed or copied to another folder. Keys of older versions (path, size and date) are still read.
enum TranscriptCache {
    struct Entry: Codable {
        var transcript: Transcript
        var cues: [Cue]
        var edited: Bool
        var layoutKey: String
        var modelID: String
        var groups: [SubtitleGroup]?
        /// The preset the video was styled with: it comes back with the video.
        var presetID: UUID?
    }

    /// How much of each end of the file goes into the key.
    private static let sample = 1 << 20

    /// The key of the file's content, nil when it cannot be read.
    static func key(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var data = Data("subline-cache-2|\(size)|".utf8)
        do {
            try handle.seek(toOffset: 0)
            data.append(try handle.read(upToCount: sample) ?? Data())
            if size > UInt64(sample) {
                try handle.seek(toOffset: max(UInt64(sample), size - UInt64(sample)))
                data.append(try handle.read(upToCount: sample) ?? Data())
            }
        } catch {
            return nil
        }
        return sha256Hex(data)
    }

    /// The key of older versions: path, size and modification date.
    static func legacyKey(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let source = "\(url.standardizedFileURL.path)|\(size)|\(Int(modified))"
        return sha256Hex(Data(source.utf8))
    }

    private static func file(_ key: String) -> URL {
        AppPaths.cacheDir.appendingPathComponent("\(key).json")
    }

    static func load(for url: URL) -> Entry? {
        load(key: key(for: url), url: url)
    }

    /// The saved work of the file whose content key is `key` (or of the same file under the key of an older version).
    static func load(key: String?, url: URL) -> Entry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for candidate in [key, legacyKey(for: url)].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: file(candidate)), let entry = try? decoder.decode(Entry.self, from: data) {
                return entry
            }
        }
        return nil
    }

    static func save(_ entry: Entry, for url: URL) {
        guard let key = key(for: url) else { return }
        save(entry, key: key, url: url)
    }

    /// Writes the work under the content key; the copy under the old key of this file goes.
    static func save(_ entry: Entry, key: String, url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: file(key), options: .atomic)
        if let legacy = legacyKey(for: url), legacy != key {
            try? FileManager.default.removeItem(at: file(legacy))
        }
    }
}
