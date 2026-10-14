import Foundation
import MeetingASREngine

/// 模型下载器：首次启动时从 GitHub Release 下载模型到 Application Support。
@MainActor
public final class ModelDownloader: ObservableObject {
    @Published public var state: DownloadState = .idle
    @Published public var progress: Double = 0.0
    @Published public var statusMessage: String = ""

    public enum DownloadState {
        case idle
        case downloading
        case extracting
        case verifying
        case completed
        case failed(Error)
    }

    public enum DownloadError: Error, LocalizedError {
        case downloadFailed(String)
        case extractFailed(String)
        case verifyFailed(String)
        case destinationError(String)

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let msg): return "下载失败：\(msg)"
            case .extractFailed(let msg): return "解压失败：\(msg)"
            case .verifyFailed(let msg): return "校验失败：\(msg)"
            case .destinationError(let msg): return "目录错误：\(msg)"
            }
        }
    }

    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    /// 检查模型是否存在。
    public static func modelsExist() -> Bool {
        ModelPaths.locate() != nil
    }

    /// 获取用户模型目录。
    public static func userModelsDirectory() -> URL? {
        ModelPaths.userModelsDirectory
    }

    /// 下载并安装模型。
    public func downloadModels() async {
        guard case .idle = state else { return }

        state = .downloading
        statusMessage = "正在下载模型文件..."
        progress = 0.0

        do {
            // 1. 确定目标目录
            guard let destDir = ModelPaths.userModelsDirectory else {
                throw DownloadError.destinationError("无法确定 Application Support 目录")
            }

            // 2. 创建临时下载目录
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let archivePath = tmpDir.appendingPathComponent("models.tar.bz2")

            // 3. 下载模型包
            try await downloadFile(
                from: modelDownloadURL(),
                to: archivePath
            )

            // 4. 解压
            state = .extracting
            statusMessage = "正在解压模型..."
            progress = 0.0
            try await extractArchive(archivePath, to: destDir)

            // 5. 验证
            state = .verifying
            statusMessage = "正在验证模型..."
            progress = 0.0
            try verifyModels(at: destDir)

            // 6. 完成
            state = .completed
            statusMessage = "模型下载完成"
            progress = 1.0

        } catch {
            state = .failed(error)
            statusMessage = error.localizedDescription
        }
    }

    /// 取消下载。
    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        observation = nil
        state = .idle
        statusMessage = ""
        progress = 0.0
    }

    // MARK: - Private

    private func modelDownloadURL() -> URL {
        // 从本项目的 GitHub Release 下载打包好的模型
        let owner = "wjzhangq"  // GitHub 用户名
        let repo = "MeetingASR"  // 仓库名
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/meetingasr-models.tar.bz2")!
    }

    private func downloadFile(from url: URL, to destination: URL) async throws {
        let session = URLSession.shared

        return try await withCheckedThrowingContinuation { continuation in
            downloadTask = session.downloadTask(with: url) { [weak self] tempURL, response, error in
                guard let self = self else { return }

                if let error = error {
                    continuation.resume(throwing: DownloadError.downloadFailed(error.localizedDescription))
                    return
                }

                guard let tempURL = tempURL else {
                    continuation.resume(throwing: DownloadError.downloadFailed("未收到文件"))
                    return
                }

                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: DownloadError.downloadFailed(error.localizedDescription))
                }
            }

            // 监听下载进度
            observation = downloadTask?.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in
                    self?.progress = progress.fractionCompleted
                }
            }

            downloadTask?.resume()
        }
    }

    private func extractArchive(_ archive: URL, to destination: URL) async throws {
        // 确保目标目录的父目录存在
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // 删除旧的模型目录（如果存在）
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        // 使用 tar 命令解压，归档包内是 models/ 目录，我们要提取其内容到目标位置
        // tar -xjf archive.tar.bz2 --strip-components=1 -C destination/
        // 这样 models/asr/... 变成 destination/asr/...
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "--strip-components=1", "-C", destination.path]

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: DownloadError.extractFailed("tar 退出码 \(process.terminationStatus)"))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: DownloadError.extractFailed(error.localizedDescription))
            }
        }
    }

    private func verifyModels(at directory: URL) throws {
        let paths = ModelPaths(root: directory)
        try paths.validate()
    }
}
