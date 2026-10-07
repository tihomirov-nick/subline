import Foundation
import CoreGraphics

public enum MediaError: LocalizedError {
    case ffmpegNotFound
    case unreadable(String)
    case noAudio
    case noVideo
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: return L("Не найден встроенный ffmpeg. Переустановите приложение.")
        case .unreadable(let details): return L("Не удалось открыть файл как видео или аудио.\n%@", "\(details)")
        case .noAudio: return L("В файле нет звуковой дорожки, распознавать нечего.")
        case .noVideo: return L("В файле нет видеодорожки. Для аудио можно сохранить только SRT.")
        case .failed(let details): return L("Ошибка ffmpeg:\n%@", "\(details)")
        case .cancelled: return L("Отменено.")
        }
    }
}

/// Information about a media file, parsed from ffmpeg output.
public struct MediaInfo: Sendable {
    public var url: URL
    public var duration: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Display size: rotation metadata applied (what the viewer sees and what ffmpeg filters receive).
    public var width: Int
    public var height: Int
    public var fps: Double?
    public var videoCodec: String?
    public var pixelFormat: String?
    public var videoBitrateKbps: Int?
    public var audioCodec: String?
    public var rotation: Int
    /// Color tags as ffmpeg names them (e.g. "bt709", "bt2020", "arib-std-b67"); nil when unknown.
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorSpace: String?

    public var size: CGSize { CGSize(width: width, height: height) }

    /// HLG (iPhone) or PQ (HDR10) video.
    public var isHDR: Bool {
        colorTransfer == "arib-std-b67" || colorTransfer == "smpte2084"
    }

    /// Filter that converts HDR frames to SDR BT.709 (tone mapping), or nil for SDR video.
    public var hdrToSDRFilter: String? {
        guard isHDR, let transfer = colorTransfer else { return nil }
        let space = colorSpace ?? "bt2020nc"
        let primaries = colorPrimaries ?? "bt2020"
        return "zscale=tin=\(transfer):min=\(space):pin=\(primaries):t=linear:npl=100,format=gbrpf32le,"
            + "zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
    }

    public var isHighBitDepth: Bool {
        guard let pf = pixelFormat else { return false }
        return pf.contains("p10") || pf.contains("p12") || pf.contains("p16") || pf.hasPrefix("p010")
            || pf.hasPrefix("x2rgb10") || pf.contains("10le") || pf.contains("10be") || pf.contains("12le")
    }

    public var summary: String {
        var parts: [String] = []
        if hasVideo { parts.append("\(width)×\(height)") }
        if let fps { parts.append(String(format: fps.rounded() == fps ? "%.0f fps" : "%.2f fps", fps)) }
        parts.append(formatTimecode(duration, short: true))
        if let codec = videoCodec { parts.append(codec.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

/// Runs the bundled ffmpeg binary.
public enum FFmpeg {
    public static func executable() throws -> URL {
        guard let url = AppPaths.ffmpegURL else { throw MediaError.ffmpegNotFound }
        return url
    }

    public struct Result {
        public let status: Int32
        public let stderr: String
    }

    /// Runs ffmpeg with the arguments. `onStdoutLine` receives lines printed to stdout (used with `-progress pipe:1`).
    /// Cancelling the calling task terminates the process.
    @discardableResult
    public static func run(_ arguments: [String], allowFailure: Bool = false, onStdoutLine: ((String) -> Void)? = nil) async throws -> Result {
        let executable = try executable()
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector(onLine: onStdoutLine)
        let readers = DispatchGroup()

        let result: Result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { finished in
                    readers.notify(queue: .global()) {
                        collector.finish()
                        continuation.resume(returning: Result(status: finished.terminationStatus, stderr: collector.stderrText))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: MediaError.failed(error.localizedDescription))
                    return
                }
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    let handle = stdoutPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        collector.appendStdout(data)
                    }
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    let handle = stderrPipe.fileHandleForReading
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        collector.appendStderr(data)
                    }
                    readers.leave()
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        if Task.isCancelled { throw MediaError.cancelled }
        if result.status != 0 && !allowFailure {
            throw MediaError.failed(lastLines(result.stderr, count: 8))
        }
        return result
    }

    static func lastLines(_ text: String, count: Int) -> String {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Parses `out_time_us=` lines of `-progress` output into seconds.
    static func progressSeconds(_ line: String) -> Double? {
        if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
            guard let value = Double(line.split(separator: "=").last ?? "") else { return nil }
            return value / 1_000_000
        }
        return nil
    }

    // MARK: - Probe

    public static func probe(_ url: URL) async throws -> MediaInfo {
        let result = try await run(["-hide_banner", "-nostdin", "-i", url.path], allowFailure: true)
        guard var info = parseProbe(result.stderr, url: url) else {
            throw MediaError.unreadable(lastLines(result.stderr, count: 3))
        }
        if info.duration <= 0, info.hasAudio || info.hasVideo {
            info.duration = try await measureDuration(url)
        }
        return info
    }

    /// Decodes the file quickly to find its duration when the container does not store it.
    static func measureDuration(_ url: URL) async throws -> Double {
        var last = 0.0
        _ = try await run(["-hide_banner", "-nostdin", "-loglevel", "error", "-i", url.path, "-map", "0:a:0?", "-map", "0:v:0?",
                           "-c", "copy", "-f", "null", "-progress", "pipe:1", "-nostats", "-"], allowFailure: true) { line in
            if let t = progressSeconds(line) { last = max(last, t) }
        }
        return last
    }

    static func parseProbe(_ text: String, url: URL) -> MediaInfo? {
        let lines = text.components(separatedBy: .newlines)
        var duration = 0.0
        var hasVideo = false
        var hasAudio = false
        var width = 0, height = 0
        var fps: Double?
        var codec: String?
        var pixelFormat: String?
        var bitrate: Int?
        var audioCodec: String?
        var rotation = 0
        var inVideoStream = false
        var primaries: String?
        var transfer: String?
        var matrix: String?

        for line in lines {
            if let match = firstMatch(#"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, in: line),
               let h = Double(match[1]), let m = Double(match[2]), let s = Double(match[3]) {
                duration = h * 3600 + m * 60 + s
            }
            if line.contains("Stream #") {
                inVideoStream = false
                if line.contains("Video:") && !line.contains("(attached pic)") && !hasVideo {
                    hasVideo = true
                    inVideoStream = true
                    codec = firstMatch(#"Video: ([A-Za-z0-9_]+)"#, in: line)?[1]
                    pixelFormat = firstMatch(#"Video: [^,]*?, ([a-z][a-z0-9_]*)"#, in: line)?[1]
                    if let size = firstMatch(#", (\d{2,5})x(\d{2,5})"#, in: line) {
                        width = Int(size[1]) ?? 0
                        height = Int(size[2]) ?? 0
                    }
                    if let f = firstMatch(#"([\d.]+) fps"#, in: line) { fps = Double(f[1]) }
                    else if let f = firstMatch(#"([\d.]+) tbr"#, in: line) { fps = Double(f[1]) }
                    if let b = firstMatch(#"(\d+) kb/s"#, in: line) { bitrate = Int(b[1]) }
                    if let color = firstMatch(#"Video: [^,]*?, [a-z][a-z0-9_]*\(([^)]*)\)"#, in: line) {
                        (matrix, primaries, transfer) = parseColor(color[1])
                    }
                } else if line.contains("Audio:") && !hasAudio {
                    hasAudio = true
                    audioCodec = firstMatch(#"Audio: ([A-Za-z0-9_]+)"#, in: line)?[1]
                }
            } else if inVideoStream {
                if let r = firstMatch(#"rotation of (-?\d+(?:\.\d+)?) degrees"#, in: line), let value = Double(r[1]) {
                    rotation = Int(value.rounded())
                } else if let r = firstMatch(#"^\s*rotate\s*:\s*(-?\d+)"#, in: line), let value = Int(r[1]) {
                    rotation = value
                }
            }
        }
        guard hasVideo || hasAudio else { return nil }
        let normalized = ((rotation % 360) + 360) % 360
        if normalized == 90 || normalized == 270 {
            swap(&width, &height)
        }
        if let f = fps, f <= 0 || f > 1000 { fps = nil }
        return MediaInfo(url: url, duration: duration, hasVideo: hasVideo && width > 0 && height > 0, hasAudio: hasAudio,
                         width: width, height: height, fps: fps, videoCodec: codec, pixelFormat: pixelFormat,
                         videoBitrateKbps: bitrate, audioCodec: audioCodec, rotation: normalized,
                         colorPrimaries: primaries, colorTransfer: transfer, colorSpace: matrix)
    }

    /// "tv, bt2020nc/bt2020/arib-std-b67, progressive" -> (matrix, primaries, transfer); "tv, bt709" -> all bt709.
    static func parseColor(_ text: String) -> (String?, String?, String?) {
        let tokens = text.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        func known(_ value: String) -> String? { value == "unknown" || value.isEmpty ? nil : value }
        if let triple = tokens.first(where: { $0.contains("/") }) {
            let parts = triple.split(separator: "/").map(String.init)
            if parts.count == 3 { return (known(parts[0]), known(parts[1]), known(parts[2])) }
        }
        let names: Set<String> = ["bt709", "bt470bg", "smpte170m", "bt2020nc", "bt2020c", "smpte240m"]
        if let single = tokens.first(where: { names.contains($0) }) {
            let primaries = single == "bt2020nc" || single == "bt2020c" ? "bt2020" : single
            return (single, primaries, single.hasPrefix("bt2020") ? nil : single)
        }
        return (nil, nil, nil)
    }

    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            guard let r = Range(match.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
    }

    // MARK: - Frames

    /// Extracts one frame as JPEG (rotation applied). `maxDimension` limits the bigger side.
    public static func extractFrame(from url: URL, at time: Double, maxDimension: Int?, hdrFilter: String? = nil, to output: URL) async throws {
        func attempt(_ t: Double) async throws {
            var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
            if t > 0.01 { args += ["-ss", String(format: "%.3f", t)] }
            args += ["-i", url.path, "-map", "0:v:0", "-frames:v", "1", "-an", "-sn", "-dn"]
            var filters: [String] = []
            if let hdrFilter { filters.append(hdrFilter) }
            if let m = maxDimension {
                filters.append("scale='min(\(m),iw)':'min(\(m),ih)':force_original_aspect_ratio=decrease")
            }
            if !filters.isEmpty {
                args += ["-vf", filters.joined(separator: ",")]
            }
            args += ["-q:v", "3", "-update", "1", output.path]
            try await run(args)
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await attempt(time)
        } catch MediaError.cancelled {
            throw MediaError.cancelled
        } catch {
            if time > 0.5 { try await attempt(max(0, time - 1)) } else { throw error }
        }
        if !FileManager.default.fileExists(atPath: output.path), time > 0 {
            try await attempt(0)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw MediaError.failed(L("Не удалось получить кадр из видео."))
        }
    }

    // MARK: - Playback copy

    /// Makes a copy that AVFoundation can play (for MKV, WebM, AVI, ... and codecs macOS cannot decode).
    /// H.264/HEVC streams are only re-wrapped into MP4; everything else is re-encoded with short GOPs so that
    /// scrubbing and frame stepping stay fast. HDR is tone-mapped like in the export.
    public static func makePlaybackCopy(of info: MediaInfo, to output: URL, progress: ((Double) -> Void)? = nil) async throws {
        let codec = info.videoCodec ?? ""
        let canRemux = (codec == "h264" || codec == "hevc") && !info.isHDR
        var attempts: [[String]] = []
        for hardware in [true, false] {
            var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", info.url.path,
                        "-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn"]
            if info.hasVideo {
                if canRemux && hardware {
                    args += ["-c:v", "copy"]
                    if codec == "hevc" { args += ["-tag:v", "hvc1"] }
                } else {
                    var filters: [String] = []
                    if let hdr = info.hdrToSDRFilter { filters.append(hdr) }
                    filters.append("scale='min(1920,iw)':'min(1920,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2")
                    filters.append("format=yuv420p")
                    args += ["-vf", filters.joined(separator: ",")]
                    if hardware {
                        args += ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-allow_sw", "1", "-g", "15"]
                    } else {
                        args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-g", "15"]
                    }
                }
            }
            if info.hasAudio {
                args += ["-c:a", "aac", "-b:a", "160k", "-ac", "2"]
            }
            args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
            attempts.append(args)
        }

        var lastError: Error?
        for arguments in attempts {
            do {
                try await run(arguments) { line in
                    if let t = progressSeconds(line), info.duration > 0 { progress?(min(1, t / info.duration)) }
                }
                return
            } catch MediaError.cancelled {
                try? FileManager.default.removeItem(at: output)
                throw MediaError.cancelled
            } catch {
                lastError = error
            }
        }
        try? FileManager.default.removeItem(at: output)
        throw lastError ?? MediaError.failed(L("Не удалось подготовить видео для просмотра."))
    }

    // MARK: - Audio for Whisper

    /// Decodes the first audio track to 16 kHz mono float samples. Silence is added at the beginning when the
    /// audio starts later than the video, so timestamps match the video timeline.
    public static func extractAudioSamples(from url: URL, workDir: URL, duration: Double, progress: ((Double) -> Void)? = nil) async throws -> [Float] {
        let output = workDir.appendingPathComponent("audio.f32")
        try? FileManager.default.removeItem(at: output)
        try await run([
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-i", url.path,
            "-map", "0:a:0", "-vn", "-sn", "-dn",
            "-af", "aresample=async=1:first_pts=0",
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_f32le", "-f", "f32le",
            "-progress", "pipe:1", "-nostats",
            output.path,
        ]) { line in
            if let t = progressSeconds(line), duration > 0 { progress?(min(1, t / duration)) }
        }
        let data = try Data(contentsOf: output)
        try? FileManager.default.removeItem(at: output)
        let count = data.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { buffer in
            _ = data.copyBytes(to: buffer)
        }
        return samples
    }
}

/// Collects process output; splits stdout into lines.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrData = Data()
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    func appendStdout(_ data: Data) {
        guard let onLine else { return }
        lock.lock()
        stdoutBuffer.append(data)
        var lines: [String] = []
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        if stderrData.count > 2_000_000 {
            stderrData = stderrData.suffix(1_000_000)
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let rest = stdoutBuffer
        stdoutBuffer.removeAll()
        lock.unlock()
        if !rest.isEmpty, let onLine {
            onLine(String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }
}
