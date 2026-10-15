import Foundation
import MeetingASRCore
import MeetingASREngine

/// 额外识别模型（FireRedASR）的下载安装：从 sherpa-onnx 发布页下载，解压到用户模型目录。
@MainActor
final class AsrModelInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case extracting
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var installing: AsrModelKind?

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    /// 模型是否已安装（包内或用户模型目录）。
    static func isInstalled(_ kind: AsrModelKind) -> Bool {
        if let paths = ModelPaths.locate() { return paths.hasASR(kind) }
        guard let user = ModelPaths.userModelsDirectory else { return false }
        return ModelPaths(root: user).hasASR(kind)
    }

    func install(_ kind: AsrModelKind, completion: @escaping (Bool) -> Void) {
        guard installing == nil, let userDir = ModelPaths.userModelsDirectory else { return }
        installing = kind
        state = .downloading(0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("masr-asr-\(UUID().uuidString)")
        let t = URLSession.shared.downloadTask(with: kind.releaseURL) { [weak self] url, response, error in
            var archive: URL?
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "HTTP \(http.statusCode)"
            } else if let url {
                // 临时文件在回调返回后即被删除，先移走
                do {
                    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    let a = tmp.appendingPathComponent("model.tar.bz2")
                    try FileManager.default.moveItem(at: url, to: a)
                    archive = a
                } catch {
                    failure = error.localizedDescription
                }
            }
            Task { @MainActor in
                guard let self else { return }
                if let archive {
                    self.extract(kind, archive: archive, tmp: tmp, into: userDir, completion: completion)
                } else {
                    try? FileManager.default.removeItem(at: tmp)
                    self.finish(failure ?? "下载失败", completion: completion)
                }
            }
        }
        observation = t.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.state { self?.state = .downloading(f) }
            }
        }
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
    }

    private func extract(_ kind: AsrModelKind, archive: URL, tmp: URL, into userDir: URL, completion: @escaping (Bool) -> Void) {
        state = .extracting
        let unpack = tmp.appendingPathComponent("unpack")
        DispatchQueue.global(qos: .utility).async {
            var failure: String?
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                p.arguments = ["-xjf", archive.path, "--strip-components=1", "-C", unpack.path]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw NSError(domain: "tar", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "解压失败（tar 退出码 \(p.terminationStatus)）"]) }
                // 只保留运行所需文件
                let dest = userDir.appendingPathComponent(kind.directory)
                try? fm.removeItem(at: dest)
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for f in kind.requiredFiles {
                    let src = unpack.appendingPathComponent(f)
                    guard fm.fileExists(atPath: src.path) else {
                        throw NSError(domain: "model", code: 1, userInfo: [NSLocalizedDescriptionKey: "模型包中缺少 \(f)"])
                    }
                    try fm.moveItem(at: src, to: dest.appendingPathComponent(f))
                }
            } catch {
                failure = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: tmp)
            Task { @MainActor in
                self.finish(failure, completion: completion)
            }
        }
    }

    private func finish(_ failure: String?, completion: (Bool) -> Void) {
        task = nil
        observation = nil
        installing = nil
        state = failure.map { .failed($0) } ?? .idle
        completion(failure == nil)
    }
}
