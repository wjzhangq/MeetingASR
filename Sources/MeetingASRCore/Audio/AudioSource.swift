import Foundation

/// 可按帧范围随机读取的单声道音频源（WAV 或 AVFoundation 解码的文件）。
public protocol MonoAudioSource: AnyObject {
    var sampleRate: Int { get }
    var frameCount: Int64 { get }
    func readMono(startFrame: Int64, count: Int) -> [Float]
}

extension WavReader: MonoAudioSource {}

/// 打开音频文件：WAV 走内置读取器；其他格式（m4a/mp3/aac/flac）在 macOS 上用 AVFoundation 解码（FR-F2）。
public enum AudioFileOpener {
    public static let supportedExtensions = ["wav", "m4a", "mp3", "aac", "flac", "caf", "aif", "aiff"]

    public static func open(_ url: URL) throws -> MonoAudioSource {
        let ext = url.pathExtension.lowercased()
        if ext == "wav", let r = try? WavReader(url: url) {
            return r
        }
        #if canImport(AVFoundation)
        return try AVAudioFileSource(url: url)
        #else
        if ext == "wav" { return try WavReader(url: url) }
        throw WavError.unsupported("当前平台仅支持 WAV：\(url.lastPathComponent)")
        #endif
    }
}

#if canImport(AVFoundation)
import AVFoundation

/// 基于 AVAudioFile 的解码源，按需读取，不一次性载入。
public final class AVAudioFileSource: MonoAudioSource {
    private let file: AVAudioFile
    public let sampleRate: Int
    public let frameCount: Int64
    private let channels: Int

    public init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        sampleRate = Int(file.processingFormat.sampleRate)
        channels = Int(file.processingFormat.channelCount)
        frameCount = file.length
    }

    public func readMono(startFrame: Int64, count: Int) -> [Float] {
        let start = max(0, min(startFrame, frameCount))
        let n = Int(max(0, min(Int64(count), frameCount - start)))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else { return [] }
        file.framePosition = start
        do { try file.read(into: buf, frameCount: AVAudioFrameCount(n)) } catch { return [] }
        let frames = Int(buf.frameLength)
        guard let ch = buf.floatChannelData else { return [] }
        var out = [Float](repeating: 0, count: frames)
        let inv = 1 / Float(channels)
        for c in 0..<channels {
            let p = ch[c]
            for i in 0..<frames { out[i] += p[i] * inv }
        }
        return out
    }
}
#endif
