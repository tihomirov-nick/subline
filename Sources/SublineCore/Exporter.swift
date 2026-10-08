import Foundation
import CoreGraphics

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case mp4H264
    case mp4HEVC
    case movProRes
    case overlayProRes4444
    case srt

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mp4H264: return L("Видео с субтитрами в MP4 (H.264)")
        case .mp4HEVC: return L("Видео с субтитрами в MP4 (HEVC / H.265)")
        case .movProRes: return L("Видео с субтитрами в MOV (ProRes 422 HQ)")
        case .overlayProRes4444: return L("Только субтитры на прозрачном фоне в MOV (ProRes 4444)")
        case .srt: return L("Файл субтитров SRT")
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC: return "mp4"
        case .movProRes, .overlayProRes4444: return "mov"
        case .srt: return "srt"
        }
    }

    public var fileSuffix: String {
        switch self {
        case .overlayProRes4444: return L("_субтитры_alpha")
        case .srt: return ""
        default: return L("_субтитры")
        }
    }

    public var needsVideo: Bool { self != .srt }
}

/// Renders subtitles into video files with ffmpeg.
public enum Exporter {
    /// Renders every cue into a full-frame transparent PNG and writes an ffconcat list that shows each image
    /// for the duration of its cue (empty frames in between).
    public static func prepareOverlay(
        cues: [Cue], renderer: CueRenderer, duration: Double, workDir: URL,
        progress: ((Double) -> Void)? = nil, isCancelled: () -> Bool = { false }
    ) throws -> URL {
        let canvas = renderer.canvas
        guard let context = CueRenderer.makeContext(canvas: canvas, pixelSize: canvas),
              let blank = context.makeImage() else {
            throw MediaError.failed(L("Не удалось подготовить кадры субтитров"))
        }
        try CueRenderer.writePNG(blank, to: workDir.appendingPathComponent("blank.png"))

        let sorted = cues.filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var entries: [(file: String, duration: Double)] = []
        var cursor = 0.0
        let limit = duration > 0 ? duration : (sorted.last?.end ?? 0)
        for (index, cue) in sorted.enumerated() {
            if isCancelled() { throw MediaError.cancelled }
            let start = max(cue.start, cursor)
            let end = min(cue.end, limit)
            guard end - start >= 0.02 else { continue }
            if start - cursor >= 0.001 {
                entries.append(("blank.png", start - cursor))
            }
            context.clear(CGRect(origin: .zero, size: canvas))
            if let layout = renderer.layout(cue) {
                renderer.draw(layout, in: context)
            }
            guard let image = context.makeImage() else { continue }
            let name = String(format: "cue_%05d.png", index)
            try CueRenderer.writePNG(image, to: workDir.appendingPathComponent(name))
            entries.append((name, end - start))
            cursor = end
            progress?(Double(index + 1) / Double(max(1, sorted.count)))
        }
        entries.append(("blank.png", max(1, limit - cursor + 1)))

        var list = "ffconcat version 1.0\n"
        for entry in entries {
            list += "file '\(entry.file)'\noption framerate 1000\nduration \(String(format: "%.6f", entry.duration))\n"
        }
        // The concat demuxer ignores the duration of the last entry, so the last image is listed once more.
        list += "file 'blank.png'\noption framerate 1000\n"
        let listURL = workDir.appendingPathComponent("subtitles.ffconcat")
        try list.write(to: listURL, atomically: true, encoding: .utf8)
        return listURL
    }

    /// Target video bitrate in kbit/s: enough headroom over the source to avoid visible re-encoding loss.
    static func videoBitrate(for info: MediaInfo, hevc: Bool) -> Int {
        let fps = min(info.fps ?? 30, 120)
        let pixelsPerSecond = Double(info.width * info.height) * fps
        var kbps = pixelsPerSecond * 0.14 / 1000
        if let source = info.videoBitrateKbps {
            kbps = max(kbps, Double(source) * 1.1)
        }
        kbps = min(kbps, pixelsPerSecond * 0.45 / 1000)
        kbps = max(kbps, 2000)
        if hevc { kbps *= 0.7 }
        return Int(kbps)
    }

    /// Burns subtitles into the video (or writes a transparent overlay) and reports progress 0...1.
    public static func exportVideo(
        info: MediaInfo, cues: [Cue], groups: [SubtitleGroup] = [], preset: SubtitlePreset, format: ExportFormat, output: URL,
        progress: @escaping (String, Double) -> Void
    ) async throws {
        guard info.hasVideo else { throw MediaError.noVideo }
        let workDir = AppPaths.makeTempDir("export")
        defer { try? FileManager.default.removeItem(at: workDir) }

        progress(L("Готовлю субтитры…"), 0)
        let renderer = CueRenderer(preset: preset, groups: groups, canvas: info.size)
        let listURL = try prepareOverlay(cues: cues, renderer: renderer, duration: info.duration, workDir: workDir,
                                         progress: { progress(L("Готовлю субтитры…"), $0 * 0.05) },
                                         isCancelled: { Task.isCancelled })
        try Task.checkCancellation()

        let partial = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).part.\(output.pathExtension)")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        var attempts: [[String]] = []
        switch format {
        case .overlayProRes4444:
            attempts.append(overlayArguments(listURL: listURL, info: info, output: partial))
        case .mp4H264, .mp4HEVC, .movProRes:
            attempts.append(burnArguments(listURL: listURL, info: info, format: format, hardware: true, output: partial))
            if format != .movProRes {
                attempts.append(burnArguments(listURL: listURL, info: info, format: format, hardware: false, output: partial))
            }
        case .srt:
            throw MediaError.failed(L("SRT сохраняется без кодирования видео"))
        }

        var lastError: Error?
        for (index, arguments) in attempts.enumerated() {
            do {
                progress(index == 0 ? L("Кодирую видео…") : L("Кодирую видео программным кодеком…"), 0.05)
                try await FFmpeg.run(arguments) { line in
                    if let t = FFmpeg.progressSeconds(line), info.duration > 0 {
                        progress(L("Кодирую видео…"), 0.05 + 0.95 * min(1, t / info.duration))
                    }
                }
                lastError = nil
                break
            } catch MediaError.cancelled {
                throw MediaError.cancelled
            } catch {
                if Task.isCancelled { throw MediaError.cancelled }
                lastError = error
            }
        }
        if let lastError { throw lastError }

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: partial, to: output)
        progress(L("Готово"), 1)
    }

    static func burnArguments(listURL: URL, info: MediaInfo, format: ExportFormat, hardware: Bool, output: URL) -> [String] {
        // HDR is tone-mapped to SDR so the video and the subtitles look the same as in the preview.
        let hdr = info.hdrToSDRFilter
        let keepHighBitDepth = hdr == nil && info.isHighBitDepth
        let workFormat: String
        let encoderFormat: String
        var codecArgs: [String]
        switch format {
        case .mp4HEVC:
            let kbps = videoBitrate(for: info, hevc: true)
            workFormat = keepHighBitDepth ? "yuv420p10le" : "yuv420p"
            if hardware {
                encoderFormat = keepHighBitDepth ? "p010le" : "nv12"
                codecArgs = ["-c:v", "hevc_videotoolbox", "-b:v", "\(kbps)k", "-allow_sw", "1",
                             "-profile:v", keepHighBitDepth ? "main10" : "main"]
            } else {
                encoderFormat = workFormat
                codecArgs = ["-c:v", "libx265", "-preset", "medium", "-crf", "20", "-x265-params", "log-level=error"]
            }
            codecArgs += ["-tag:v", "hvc1"]
        case .movProRes:
            workFormat = "yuv422p10le"
            encoderFormat = "yuv422p10le"
            codecArgs = ["-c:v", "prores_ks", "-profile:v", "3", "-vendor", "apl0"]
        default:
            let kbps = videoBitrate(for: info, hevc: false)
            workFormat = "yuv420p"
            if hardware {
                encoderFormat = "nv12"
                codecArgs = ["-c:v", "h264_videotoolbox", "-b:v", "\(kbps)k", "-allow_sw", "1", "-profile:v", "high"]
            } else {
                encoderFormat = "yuv420p"
                codecArgs = ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-profile:v", "high"]
            }
        }
        let alphaFormat = workFormat.replacingOccurrences(of: "yuv", with: "yuva")
        let main = hdr.map { "[0:v]\($0),format=\(workFormat)[main]" } ?? "[0:v]format=\(workFormat)[main]"
        let tags = colorTags(for: info)
        var params: [String] = []
        if let primaries = tags.primaries { params.append("color_primaries=\(primaries)") }
        if let transfer = tags.transfer { params.append("color_trc=\(transfer)") }
        if let space = tags.space { params.append("colorspace=\(space)") }
        let setParams = params.isEmpty ? "" : ",setparams=" + params.joined(separator: ":")
        let filter = [
            main,
            // Subtitles are drawn in sRGB; convert with the HD matrix so colored text keeps its color.
            "[1:v]format=rgba,scale=out_color_matrix=bt709:out_range=tv,format=\(alphaFormat)[subs]",
            "[main][subs]overlay=x=0:y=0:eof_action=pass:format=auto\(setParams),format=\(encoderFormat)[v]",
        ].joined(separator: ";")

        var args = [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-i", info.url.path,
            "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-filter_complex", filter,
            "-map", "[v]", "-map", "0:a:0?",
            "-map_metadata", "0",
        ]
        args += codecArgs
        if let primaries = tags.primaries { args += ["-color_primaries", primaries] }
        if let transfer = tags.transfer { args += ["-color_trc", transfer] }
        if let space = tags.space { args += ["-colorspace", space] }
        if format == .movProRes {
            args += ["-c:a", "pcm_s16le"]
        } else {
            args += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        }
        args += ["-progress", "pipe:1", "-nostats", output.path]
        return args
    }

    /// Output color tags: BT.709 after tone mapping, otherwise the source tags (BT.709 for untagged HD video).
    static func colorTags(for info: MediaInfo) -> (primaries: String?, transfer: String?, space: String?) {
        if info.isHDR || (info.colorSpace == nil && info.colorPrimaries == nil && info.height >= 720 && info.width >= 720) {
            return ("bt709", "bt709", "bt709")
        }
        return (info.colorPrimaries, info.colorTransfer, info.colorSpace)
    }

    static func overlayArguments(listURL: URL, info: MediaInfo, output: URL) -> [String] {
        let fps = info.fps.map { String(format: "%.5f", $0) } ?? "30"
        return [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-t", String(format: "%.3f", max(0.1, info.duration)),
            "-vf", "fps=\(fps),format=yuva444p10le",
            "-c:v", "prores_ks", "-profile:v", "4444", "-alpha_bits", "16", "-vendor", "apl0",
            "-progress", "pipe:1", "-nostats", output.path,
        ]
    }

    // MARK: - SRT

    /// SubRip text with the case/punctuation mode and line breaks of each subtitle.
    public static func srt(cues: [Cue], renderer: CueRenderer) -> String {
        var out = ""
        var index = 1
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let lines = renderer.displayLines(cue)
            guard !lines.isEmpty else { continue }
            out += "\(index)\n\(srtTime(cue.start)) --> \(srtTime(cue.end))\n\(lines.joined(separator: "\n"))\n\n"
            index += 1
        }
        return out
    }

    static func srtTime(_ seconds: Double) -> String {
        let totalMs = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", totalMs / 3_600_000, (totalMs / 60_000) % 60, (totalMs / 1000) % 60, totalMs % 1000)
    }
}
