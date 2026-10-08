import Foundation
import CWhisper

public struct WhisperOptions: Sendable {
    public var modelPath: String
    /// ISO code ("ru", "en", ...) or "auto".
    public var language: String
    /// Optional hint with names and terms that appear in the video.
    public var prompt: String
    public var beamSearch: Bool
    /// Voice activity detection (Silero) — skips silence and music, reduces hallucinations.
    public var vadModelPath: String?
    public var useGPU: Bool
    public var threads: Int
    /// Word timing from cross-attention alignment (DTW) instead of timestamp-token heuristics.
    public var dtw: Bool

    public init(modelPath: String, language: String = "ru", prompt: String = "", beamSearch: Bool = true,
                vadModelPath: String? = nil, useGPU: Bool = WhisperEngine.gpuAvailable, threads: Int = WhisperEngine.defaultThreads,
                dtw: Bool = true) {
        self.modelPath = modelPath
        self.language = language
        self.prompt = prompt
        self.beamSearch = beamSearch
        self.vadModelPath = vadModelPath
        self.useGPU = useGPU
        self.threads = threads
        self.dtw = dtw
    }
}

public enum WhisperError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case failed(Int32)
    case cancelled
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return L("Файл модели не найден: %@", "\(path)")
        case .modelLoadFailed(let name): return L("Не удалось загрузить модель «%@». Возможно, файл поврежден, удалите модель и скачайте ее заново", "\(name)")
        case .failed(let code): return L("Ошибка распознавания (код %@)", "\(code)")
        case .cancelled: return L("Распознавание отменено")
        case .emptyAudio: return L("Звуковая дорожка пустая")
        }
    }
}

/// Speech recognition with whisper.cpp (Metal on Apple Silicon).
public enum WhisperEngine {
    public static var defaultThreads: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// Metal is used on Apple Silicon; Intel Macs run on the CPU.
    public static var gpuAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static var version: String { String(cString: whisper_version()) }

    private static let warmUpLock = NSLock()
    private static var warmUpState = 0 // 0 = not started, 1 = running, 2 = done

    /// True while the GPU kernels are being compiled (only after installing or updating the app).
    public static var isWarmingUp: Bool {
        warmUpLock.lock()
        defer { warmUpLock.unlock() }
        return warmUpState == 1
    }

    /// Initializes the Metal backend so its kernels are compiled (and cached by macOS) before the first
    /// recognition. The first launch of a new app build takes ~10-30 s; later launches are instant.
    public static func warmUp() {
        guard gpuAvailable else { return }
        warmUpLock.lock()
        guard warmUpState == 0 else {
            warmUpLock.unlock()
            return
        }
        warmUpState = 1
        warmUpLock.unlock()
        if let device = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU),
           let backend = ggml_backend_dev_init(device, nil) {
            ggml_backend_free(backend)
        }
        warmUpLock.lock()
        warmUpState = 2
        warmUpLock.unlock()
    }

    /// Silences whisper.cpp's own log output (model loading details etc.).
    public static func setLoggingEnabled(_ enabled: Bool) {
        if enabled {
            whisper_log_set(nil, nil)
        } else {
            whisper_log_set({ _, _, _ in }, nil)
        }
    }

    /// Supported languages (code, name in the interface language) for the language picker.
    public static let languages: [(code: String, name: String)] = [
        ("ru", L("Русский")), ("auto", L("Определить автоматически")), ("en", L("Английский")), ("uk", L("Украинский")),
        ("be", L("Белорусский")), ("kk", L("Казахский")), ("uz", L("Узбекский")), ("hy", L("Армянский")), ("ka", L("Грузинский")),
        ("az", L("Азербайджанский")), ("de", L("Немецкий")), ("fr", L("Французский")), ("es", L("Испанский")),
        ("it", L("Итальянский")), ("pt", L("Португальский")), ("pl", L("Польский")), ("tr", L("Турецкий")),
        ("zh", L("Китайский")), ("ja", L("Японский")), ("ko", L("Корейский")), ("ar", L("Арабский")), ("he", L("Иврит")),
    ]

    private final class Callbacks {
        let progress: (Double) -> Void
        let isCancelled: () -> Bool
        init(progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) {
            self.progress = progress
            self.isCancelled = isCancelled
        }
    }

    /// Runs recognition on 16 kHz mono samples. Blocking — call from a background thread.
    public static func transcribe(
        samples: [Float], options: WhisperOptions,
        progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> (segments: [TranscriptSegment], language: String) {
        guard !samples.isEmpty else { throw WhisperError.emptyAudio }
        guard FileManager.default.fileExists(atPath: options.modelPath) else {
            throw WhisperError.modelNotFound(options.modelPath)
        }
        if isCancelled() { throw WhisperError.cancelled }

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = options.useGPU
        let alignmentHeads = options.dtw ? dtwPreset(forModelAt: options.modelPath) : nil
        if let alignmentHeads {
            // DTW needs the attention weights, which flash attention does not produce.
            contextParams.flash_attn = false
            contextParams.dtw_token_timestamps = true
            contextParams.dtw_aheads_preset = alignmentHeads
            if alignmentHeads == WHISPER_AHEADS_N_TOP_MOST {
                contextParams.dtw_n_top = 2
            }
        } else {
            contextParams.flash_attn = options.useGPU
        }
        guard let ctx = whisper_init_from_file_with_params(options.modelPath, contextParams) else {
            throw WhisperError.modelLoadFailed(URL(fileURLWithPath: options.modelPath).lastPathComponent)
        }
        defer { whisper_free(ctx) }

        var params = whisper_full_default_params(options.beamSearch ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(options.threads)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.token_timestamps = true
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        params.temperature_inc = 0.2
        if options.beamSearch {
            params.beam_search.beam_size = 5
        } else {
            params.greedy.best_of = 5
        }

        // C strings must stay alive during whisper_full.
        var allocated: [UnsafeMutablePointer<CChar>] = []
        defer { allocated.forEach { free($0) } }
        func cString(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            allocated.append(p)
            return UnsafePointer(p)
        }

        let language = options.language.isEmpty ? "auto" : options.language
        params.language = cString(language)
        params.detect_language = false
        let prompt = options.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            params.initial_prompt = cString(prompt)
        }
        if let vad = options.vadModelPath, FileManager.default.fileExists(atPath: vad) {
            params.vad = true
            params.vad_model_path = cString(vad)
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.5
            vadParams.min_speech_duration_ms = 200
            vadParams.min_silence_duration_ms = 300
            vadParams.speech_pad_ms = 200
            params.vad_params = vadParams
        }

        let callbacks = Callbacks(progress: progress, isCancelled: isCancelled)
        let userData = Unmanaged.passUnretained(callbacks).toOpaque()
        params.progress_callback = { _, _, value, userData in
            guard let userData else { return }
            Unmanaged<Callbacks>.fromOpaque(userData).takeUnretainedValue().progress(Double(value) / 100)
        }
        params.progress_callback_user_data = userData
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<Callbacks>.fromOpaque(userData).takeUnretainedValue().isCancelled()
        }
        params.abort_callback_user_data = userData
        params.encoder_begin_callback = { _, _, userData in
            guard let userData else { return true }
            return !Unmanaged<Callbacks>.fromOpaque(userData).takeUnretainedValue().isCancelled()
        }
        params.encoder_begin_callback_user_data = userData

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }
        withExtendedLifetime(callbacks) {}
        if isCancelled() { throw WhisperError.cancelled }
        guard status == 0 else { throw WhisperError.failed(status) }

        let detected = String(cString: whisper_lang_str(whisper_full_lang_id(ctx)))
        let segments = HallucinationFilter.clean(readSegments(ctx, useDTW: alignmentHeads != nil))
        return (segments, detected)
    }

    /// Measured delay of DTW token times relative to the spoken word onset.
    static let dtwOnsetLag = 0.2

    /// Alignment heads for DTW word timing, chosen by the model file name.
    static func dtwPreset(forModelAt path: String) -> whisper_alignment_heads_preset {
        switch ProcessInfo.processInfo.environment["SUBLINE_DTW_HEADS"] {
        case "large-v3": return WHISPER_AHEADS_LARGE_V3
        case "top": return WHISPER_AHEADS_N_TOP_MOST
        default: break
        }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name.contains("large-v3-turbo") { return WHISPER_AHEADS_LARGE_V3_TURBO }
        // Fine-tunes of large-v3 (e.g. the Russian models) keep its alignment heads.
        if name.contains("large-v3") { return WHISPER_AHEADS_LARGE_V3 }
        if name.contains("large-v2") { return WHISPER_AHEADS_LARGE_V2 }
        if name.contains("large-v1") { return WHISPER_AHEADS_LARGE_V1 }
        if name.contains("medium.en") { return WHISPER_AHEADS_MEDIUM_EN }
        if name.contains("medium") { return WHISPER_AHEADS_MEDIUM }
        if name.contains("small.en") { return WHISPER_AHEADS_SMALL_EN }
        if name.contains("small") { return WHISPER_AHEADS_SMALL }
        if name.contains("base.en") { return WHISPER_AHEADS_BASE_EN }
        if name.contains("base") { return WHISPER_AHEADS_BASE }
        if name.contains("tiny.en") { return WHISPER_AHEADS_TINY_EN }
        if name.contains("tiny") { return WHISPER_AHEADS_TINY }
        return WHISPER_AHEADS_N_TOP_MOST
    }

    /// Converts whisper segments/tokens to words. Token text may split UTF-8 characters, so bytes are joined
    /// before decoding.
    static func readSegments(_ ctx: OpaquePointer, useDTW: Bool) -> [TranscriptSegment] {
        let eot = whisper_token_eot(ctx)
        var segments: [TranscriptSegment] = []
        let segmentCount = whisper_full_n_segments(ctx)
        for s in 0..<segmentCount {
            let t0 = Double(whisper_full_get_segment_t0(ctx, s)) / 100
            let t1 = max(t0, Double(whisper_full_get_segment_t1(ctx, s)) / 100)
            var words: [Word] = []
            var bytes: [UInt8] = []
            var wordStart = t0
            var wordEnd = t0
            var probabilities: [Float] = []

            func flush() {
                let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let p = probabilities.isEmpty ? 1 : probabilities.reduce(0, +) / Float(probabilities.count)
                    words.append(Word(text: text, start: wordStart, end: max(wordEnd, wordStart), probability: p))
                }
                bytes.removeAll()
                probabilities.removeAll()
            }

            let tokenCount = whisper_full_n_tokens(ctx, s)
            for t in 0..<tokenCount {
                let data = whisper_full_get_token_data(ctx, s, t)
                if data.id >= eot { continue }
                guard let cText = whisper_full_get_token_text(ctx, s, t) else { continue }
                let tokenBytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(cText).assumingMemoryBound(to: UInt8.self), count: strlen(cText)))
                guard !tokenBytes.isEmpty else { continue }
                var start = Double(data.t0) / 100
                let end = Double(data.t1) / 100
                if useDTW, data.t_dtw >= 0 {
                    // Attention alignment lags behind the actual word onset by ~0.2 s.
                    start = Double(data.t_dtw) / 100 - dtwOnsetLag
                }
                if tokenBytes.first == 0x20, !bytes.isEmpty {
                    flush()
                }
                if bytes.isEmpty {
                    wordStart = start
                }
                bytes += tokenBytes
                wordEnd = end
                probabilities.append(data.p)
            }
            flush()
            normalizeTiming(&words, segmentStart: t0, segmentEnd: t1, startsAreReliable: useDTW)

            let text = String(cString: whisper_full_get_segment_text(ctx, s)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty {
                segments.append(TranscriptSegment(start: t0, end: t1, text: text, words: words))
            }
        }
        return segments
    }

    /// Keeps word times inside the segment, ordered and without overlaps.
    static func normalizeTiming(_ words: inout [Word], segmentStart: Double, segmentEnd: Double, startsAreReliable: Bool) {
        guard !words.isEmpty else { return }
        var previousStart = segmentStart
        for i in words.indices {
            let start = min(max(words[i].start, previousStart), segmentEnd)
            words[i].start = start
            previousStart = start
        }
        for i in words.indices {
            let nextStart = i + 1 < words.count ? words[i + 1].start : segmentEnd
            var end = min(max(words[i].end, words[i].start), segmentEnd)
            if startsAreReliable {
                // Aligned starts are accurate; the end of a word cannot pass the next word's start,
                // and the last word of a phrase must not swallow the pause after it.
                let estimate = estimatedDuration(words[i].text)
                if end <= words[i].start + 0.05 { end = words[i].start + estimate }
                end = min(end, nextStart, words[i].start + max(0.6, estimate * 2.5))
            } else if end > nextStart {
                end = nextStart
            }
            words[i].end = max(end, words[i].start)
        }
    }

    /// Rough spoken duration of a word, used when the aligner gives no end time.
    static func estimatedDuration(_ text: String) -> Double {
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        return min(1.2, max(0.15, Double(letters) * 0.07))
    }
}

/// Removes typical Whisper hallucinations (credits of subtitle authors on silence, "[музыка]" etc.).
public enum HallucinationFilter {
    static let patterns: [String] = [
        "dimatorzok", "dima torzok", "субтитры сделал", "субтитры делал", "субтитры создавал", "субтитры подготовил",
        "субтитры подогнал", "редактор субтитров", "корректор а.", "а.синецкая", "а. синецкая", "субтитры:",
        "amara.org", "subtitles by",
    ]
    /// Dropped only when they are the whole segment (they can also be said for real).
    static let wholeSegmentPatterns: Set<String> = [
        "продолжение следует", "продолжение следует...", "продолжение следует…",
    ]

    public static func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { segment in
            let text = segment.text.lowercased()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if patterns.contains(where: { text.contains($0) }) { return false }
            if wholeSegmentPatterns.contains(trimmed) { return false }
            // Whole segment in brackets: [музыка], (аплодисменты), *смех*
            if let first = trimmed.first, let last = trimmed.last,
               (first == "[" && last == "]") || (first == "(" && last == ")") || (first == "*" && last == "*") {
                return false
            }
            if trimmed.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return false }
            return true
        }
    }
}
