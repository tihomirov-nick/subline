import Foundation
import CryptoKit
import SubtitsCore

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Downloads, verifies and deletes Whisper models.
@MainActor
final class ModelStore: NSObject, ObservableObject {
    struct DownloadState: Equatable {
        var received: Int64 = 0
        var total: Int64 = 0
        var bytesPerSecond: Double = 0
        var verifying = false
        var retryMessage: String?

        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var customModels: [URL] = []
    @Published var lastError: String?

    /// Called when a download finishes successfully (model id).
    var onInstalled: ((String) -> Void)?

    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var speedReference: [String: (time: Date, bytes: Int64)] = [:]
    private var attempts: [String: Int] = [:]
    private static let maxAttempts = 6

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        refresh()
    }

    func refresh() {
        installed = Set(ModelCatalog.models.filter(\.isDownloaded).map(\.id))
        customModels = ModelCatalog.customModelFiles()
    }

    var hasAnyModel: Bool { !installed.isEmpty || !customModels.isEmpty }

    /// Local file for a catalog id or a "custom:<file name>" id.
    func modelURL(for id: String) -> URL? {
        if id.hasPrefix("custom:") {
            let url = AppPaths.modelsDir.appendingPathComponent(String(id.dropFirst("custom:".count)))
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard installed.contains(id), let model = ModelCatalog.model(id: id) else { return nil }
        return model.localURL
    }

    func displayName(for id: String) -> String {
        if id.hasPrefix("custom:") { return String(id.dropFirst("custom:".count)) }
        return ModelCatalog.model(id: id)?.name ?? id
    }

    /// Installed models in catalog order, then custom files.
    var availableModelIDs: [String] {
        ModelCatalog.models.map(\.id).filter { installed.contains($0) } + customModels.map { "custom:" + $0.lastPathComponent }
    }

    // MARK: - Download

    func download(_ model: WhisperModelInfo) {
        guard tasks[model.id] == nil, downloads[model.id] == nil else { return }
        lastError = nil
        attempts[model.id] = 0
        downloads[model.id] = DownloadState(received: 0, total: model.sizeBytes)
        startTask(model.id, resumeData: nil)
    }

    private func startTask(_ id: String, resumeData: Data?) {
        guard let model = ModelCatalog.model(id: id) else { return }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: model.url)
        task.taskDescription = id
        tasks[id] = task
        speedReference[id] = (Date(), downloads[id]?.received ?? 0)
        task.resume()
    }

    /// Network problems and server errors (Hugging Face sometimes answers 5xx) are retried with a growing pause;
    /// a broken download continues from where it stopped.
    private func scheduleRetry(_ id: String, resumeData: Data?, reason: String) -> Bool {
        let attempt = (attempts[id] ?? 0) + 1
        guard attempt < Self.maxAttempts, downloads[id] != nil else { return false }
        attempts[id] = attempt
        let delay = min(30, pow(2, Double(attempt)))
        downloads[id]?.retryMessage = L("%@. Повтор через %@ с (попытка %@ из %@)…", "\(reason)", "\(Int(delay))", "\(attempt + 1)", "\(Self.maxAttempts)")
        if resumeData == nil { downloads[id]?.received = 0 }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.downloads[id] != nil, self.tasks[id] == nil else { return }
            self.downloads[id]?.retryMessage = nil
            self.startTask(id, resumeData: resumeData)
        }
        return true
    }

    func cancelDownload(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        downloads[id] = nil
    }

    func delete(_ model: WhisperModelInfo) {
        try? FileManager.default.removeItem(at: model.localURL)
        refresh()
    }

    func deleteCustom(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    /// Copies a user-provided ggml model (.bin) into the models folder.
    func importModel(from url: URL) {
        let destination = AppPaths.modelsDir.appendingPathComponent(url.lastPathComponent)
        Task.detached {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                await MainActor.run {
                    self.refresh()
                    self.onInstalled?("custom:" + destination.lastPathComponent)
                }
            } catch {
                await MainActor.run { self.lastError = L("Не удалось добавить модель: %@", "\(error.localizedDescription)") }
            }
        }
    }

    fileprivate func updateProgress(id: String, received: Int64, expected: Int64) {
        guard var state = downloads[id] else { return }
        state.received = received
        if expected > 0 { state.total = expected }
        if let reference = speedReference[id] {
            let elapsed = Date().timeIntervalSince(reference.time)
            if elapsed >= 1 {
                let speed = Double(received - reference.bytes) / elapsed
                state.bytesPerSecond = state.bytesPerSecond == 0 ? speed : state.bytesPerSecond * 0.6 + speed * 0.4
                speedReference[id] = (Date(), received)
            }
        }
        downloads[id] = state
    }

    fileprivate func finishDownload(id: String, staging: URL?, statusCode: Int, error: String?) {
        tasks[id] = nil
        guard let model = ModelCatalog.model(id: id) else { return }
        guard let staging, error == nil, (200..<300).contains(statusCode) else {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            let transient = statusCode == 429 || statusCode >= 500
            if transient, scheduleRetry(id, resumeData: nil, reason: L("Сервер временно недоступен (%@)", "\(statusCode)")) { return }
            downloads[id] = nil
            lastError = L("Не удалось скачать «%@»: %@", "\(model.name)", "\(error ?? L("ошибка сервера %@", "\(statusCode)"))")
            return
        }
        downloads[id]?.verifying = true
        Task.detached(priority: .utility) {
            var problem: String?
            let size = (try? FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? -1
            if model.sizeBytes > 0, size != model.sizeBytes {
                problem = L("размер файла не совпадает (%@ байт)", "\(size)")
            } else if let expected = model.sha256, let actual = try? Self.sha256(of: staging), actual != expected {
                problem = L("контрольная сумма не совпадает")
            }
            if problem == nil {
                try? FileManager.default.removeItem(at: model.localURL)
                do {
                    try FileManager.default.moveItem(at: staging, to: model.localURL)
                } catch {
                    problem = error.localizedDescription
                }
            } else {
                try? FileManager.default.removeItem(at: staging)
            }
            let failure = problem
            await MainActor.run {
                self.downloads[id] = nil
                if let problem = failure {
                    self.lastError = L("Модель «%@» скачалась с ошибкой: %@. Попробуйте ещё раз.", "\(model.name)", "\(problem)")
                }
                self.refresh()
                if failure == nil { self.onInstalled?(id) }
            }
        }
    }

    fileprivate func failDownload(id: String, error: Error) {
        tasks[id] = nil
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled && nsError.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
            downloads[id] = nil
            return
        }
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if scheduleRetry(id, resumeData: resumeData, reason: L("Связь прервалась")) { return }
        downloads[id] = nil
        let name = ModelCatalog.model(id: id)?.name ?? id
        lastError = L("Не удалось скачать «%@»: %@", "\(name)", "\(error.localizedDescription)")
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 8 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            self.updateProgress(id: id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // The temporary file disappears when this method returns, so move it right away.
        let staging = AppPaths.modelsDir.appendingPathComponent(".download-\(id)")
        try? FileManager.default.removeItem(at: staging)
        var moveError: String?
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            moveError = error.localizedDescription
        }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        Task { @MainActor in
            self.finishDownload(id: id, staging: moveError == nil ? staging : nil, statusCode: status, error: moveError)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        Task { @MainActor in
            self.failDownload(id: id, error: error)
        }
    }
}
