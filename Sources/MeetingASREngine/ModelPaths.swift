import Foundation
import MeetingASRCore

public enum EngineError: Error, CustomStringConvertible {
    case modelMissing(String)
    case initFailed(String)

    public var description: String {
        switch self {
        case .modelMissing(let p): return "模型文件缺失：\(p)"
        case .initFailed(let s): return "推理引擎初始化失败：\(s)"
        }
    }
}

/// 模型目录布局（由 scripts/fetch-models.sh 生成，随 App 打包在 Contents/Resources/models/）。
public struct ModelPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var asrModel: URL { root.appendingPathComponent("asr/model.int8.onnx") }
    public var asrTokens: URL { root.appendingPathComponent("asr/tokens.txt") }
    public var embedding: URL { root.appendingPathComponent("embedding/campplus.onnx") }
    public var punctuation: URL { root.appendingPathComponent("punct/model.onnx") }
    public var vad: URL { root.appendingPathComponent("vad/silero_vad.onnx") }

    /// 必需的模型文件（标点为可选）。
    /// 段流水线不用 pyannote，所以 segmentation 模型不在必需之列。
    public var required: [URL] { [asrModel, asrTokens, embedding, vad] }

    public func validate() throws {
        for url in required where !FileManager.default.fileExists(atPath: url.path) {
            throw EngineError.modelMissing(url.path)
        }
    }

    public var hasPunctuation: Bool { FileManager.default.fileExists(atPath: punctuation.path) }

    /// 某个 ASR 模型所在目录：先找模型根目录，再找用户模型目录
    /// （App 包内的模型只读，另外下载的模型放在用户模型目录）。未安装返回 nil。
    public func asrDirectory(_ kind: AsrModelKind) -> URL? {
        let roots = [root] + (Self.userModelsDirectory.map { [$0] } ?? [])
        for r in roots {
            let dir = r.appendingPathComponent(kind.directory)
            if kind.requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
                return dir
            }
        }
        return nil
    }

    public func hasASR(_ kind: AsrModelKind) -> Bool { asrDirectory(kind) != nil }

    /// 查找顺序：环境变量 MEETINGASR_MODELS → ~/Library/Application Support/MeetingASR/models → App 包内 Resources/models → 可执行文件旁的 Resources/models → 当前目录。
    public static func locate() -> ModelPaths? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MEETINGASR_MODELS"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        // 用户数据目录（App 首次启动时下载到此）
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("MeetingASR/models"))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("models"))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exe.appendingPathComponent("../Resources/models").standardizedFileURL)
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/models"))
        for c in candidates {
            let p = ModelPaths(root: c)
            if (try? p.validate()) != nil { return p }
        }
        return nil
    }

    /// 用户数据目录中的模型路径（App 首次启动时下载到此）。
    public static var userModelsDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("MeetingASR/models")
    }
}
