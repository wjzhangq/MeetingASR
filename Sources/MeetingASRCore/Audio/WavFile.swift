import Foundation

public enum WavError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case invalidFormat(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .cannotOpen(let s): return "无法打开音频文件：\(s)"
        case .invalidFormat(let s): return "WAV 格式错误：\(s)"
        case .unsupported(let s): return "不支持的 WAV 格式：\(s)"
        }
    }
}

public enum WavSampleFormat: Sendable {
    case int16
    case float32
}

/// 流式 WAV 写入器。录音过程中不断追加，结束时回填头部长度；
/// 每次 flush 都会更新头部，异常退出时已写入的数据仍可读取（FR-R9）。
public final class WavWriter {
    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public let format: WavSampleFormat
    private let handle: FileHandle
    private(set) public var framesWritten: Int64 = 0
    private var bytesSinceHeaderUpdate = 0

    public init(url: URL, sampleRate: Int, channels: Int = 1, format: WavSampleFormat = .int16) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = FileHandle(forUpdatingAtPath: url.path) else { throw WavError.cannotOpen(url.path) }
        handle = h
        handle.write(Self.header(sampleRate: sampleRate, channels: channels, format: format, dataBytes: 0))
    }

    deinit {
        try? close()
    }

    private var bytesPerSample: Int { format == .int16 ? 2 : 4 }

    public var durationSec: Double { Double(framesWritten) / Double(sampleRate) }

    /// 写入交错的 float 样本（范围 [-1, 1]）。
    public func write(interleaved samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0 else { return }
        var data: Data
        switch format {
        case .int16:
            data = Data(count: samples.count * 2)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<samples.count {
                    let v = max(-1, min(1, samples[i]))
                    p[i] = Int16(v * 32767).littleEndian
                }
            }
        case .float32:
            data = Data(count: samples.count * 4)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt32.self)
                for i in 0..<samples.count { p[i] = samples[i].bitPattern.littleEndian }
            }
        }
        handle.write(data)
        framesWritten += Int64(samples.count / channels)
        bytesSinceHeaderUpdate += data.count
        if bytesSinceHeaderUpdate > sampleRate * channels * bytesPerSample * 5 {
            updateHeader()
        }
    }

    public func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { write(interleaved: $0) }
    }

    /// 追加静音（用于暂停恢复后的对齐与断流补齐）。
    public func writeSilence(frames: Int) {
        guard frames > 0 else { return }
        let chunk = 16_000
        var remaining = frames
        let zeros = [Float](repeating: 0, count: min(chunk, frames) * channels)
        while remaining > 0 {
            let n = min(chunk, remaining)
            zeros.withUnsafeBufferPointer { write(interleaved: UnsafeBufferPointer(rebasing: $0[0..<(n * channels)])) }
            remaining -= n
        }
    }

    public func updateHeader() {
        let dataBytes = Int(framesWritten) * channels * bytesPerSample
        let end = handle.offsetInFile
        handle.seek(toFileOffset: 0)
        handle.write(Self.header(sampleRate: sampleRate, channels: channels, format: format, dataBytes: dataBytes))
        handle.seek(toFileOffset: end)
        bytesSinceHeaderUpdate = 0
    }

    private var closed = false

    public func close() throws {
        guard !closed else { return }
        closed = true
        updateHeader()
        try handle.synchronize()
        try handle.close()
    }

    static func header(sampleRate: Int, channels: Int, format: WavSampleFormat, dataBytes: Int) -> Data {
        let bps = format == .int16 ? 16 : 32
        let fmtTag: UInt16 = format == .int16 ? 1 : 3
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(fmtTag); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bps / 8)); u16(UInt16(channels * bps / 8)); u16(UInt16(bps))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        return d
    }

    /// 一次性写出单声道 float 样本。
    public static func writeMono(_ samples: [Float], sampleRate: Int, to url: URL, format: WavSampleFormat = .int16) throws {
        let w = try WavWriter(url: url, sampleRate: sampleRate, channels: 1, format: format)
        w.write(samples)
        try w.close()
    }
}

/// WAV 读取器：支持 16/24/32 位整型和 32 位浮点 PCM，可按帧范围随机读取，不必整体载入内存。
public final class WavReader {
    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let isFloat: Bool
    public let frameCount: Int64
    private let dataOffset: UInt64
    private let handle: FileHandle

    public init(url: URL) throws {
        self.url = url
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw WavError.cannotOpen(url.path) }
        handle = h
        let head = h.readData(ofLength: 12)
        guard head.count == 12, String(decoding: head[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: head[8..<12], as: UTF8.self) == "WAVE" else {
            throw WavError.invalidFormat("缺少 RIFF/WAVE 头")
        }
        var fmt: (tag: UInt16, ch: UInt16, rate: UInt32, bits: UInt16)?
        var dataStart: UInt64?
        var dataSize: UInt64 = 0
        let fileSize = h.seekToEndOfFile()
        var pos: UInt64 = 12
        while pos + 8 <= fileSize {
            h.seek(toFileOffset: pos)
            let ch = h.readData(ofLength: 8)
            guard ch.count == 8 else { break }
            let id = String(decoding: ch[0..<4], as: UTF8.self)
            let size = UInt64(ch.readLE(UInt32.self, at: 4))
            if id == "fmt " {
                let f = h.readData(ofLength: Int(min(size, 40)))
                var tag = f.readLE(UInt16.self, at: 0)
                if tag == 0xFFFE, f.count >= 26 { tag = f.readLE(UInt16.self, at: 24) } // WAVE_FORMAT_EXTENSIBLE
                fmt = (tag, f.readLE(UInt16.self, at: 2), f.readLE(UInt32.self, at: 4), f.readLE(UInt16.self, at: 14))
            } else if id == "data" {
                dataStart = pos + 8
                // 录音中断时头部长度可能未回填（为 0 或越界），以实际文件大小为准
                let avail = fileSize - (pos + 8)
                dataSize = (size == 0 || size > avail) ? avail : size
                break
            }
            pos += 8 + size + (size & 1)
        }
        guard let fmt, let dataStart else { throw WavError.invalidFormat("缺少 fmt 或 data 块") }
        guard fmt.tag == 1 || fmt.tag == 3 else { throw WavError.unsupported("format tag \(fmt.tag)") }
        guard [16, 24, 32].contains(Int(fmt.bits)) else { throw WavError.unsupported("\(fmt.bits) bit") }
        sampleRate = Int(fmt.rate)
        channels = Int(fmt.ch)
        bitsPerSample = Int(fmt.bits)
        isFloat = fmt.tag == 3
        dataOffset = dataStart
        let bytesPerFrame = UInt64(channels * bitsPerSample / 8)
        frameCount = Int64(dataSize / bytesPerFrame)
    }

    deinit {
        try? handle.close()
    }

    public var durationSec: Double { Double(frameCount) / Double(sampleRate) }

    /// 读取 [startFrame, startFrame+count) 帧，按声道平均混为单声道。
    public func readMono(startFrame: Int64, count: Int) -> [Float] {
        let start = max(0, min(startFrame, frameCount))
        let n = Int(max(0, min(Int64(count), frameCount - start)))
        guard n > 0 else { return [] }
        let bpsBytes = bitsPerSample / 8
        let bytesPerFrame = channels * bpsBytes
        handle.seek(toFileOffset: dataOffset + UInt64(start) * UInt64(bytesPerFrame))
        let data = handle.readData(ofLength: n * bytesPerFrame)
        let frames = data.count / bytesPerFrame
        var out = [Float](repeating: 0, count: frames)
        let inv = 1 / Float(channels)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<channels {
                    let p = base + f * bytesPerFrame + c * bpsBytes
                    acc += Self.sample(p, bits: bitsPerSample, isFloat: isFloat)
                }
                out[f] = acc * inv
            }
        }
        return out
    }

    /// 按秒读取单声道样本。
    public func readMono(from startSec: Double, to endSec: Double) -> [Float] {
        let s = Int64((startSec * Double(sampleRate)).rounded())
        let e = Int64((endSec * Double(sampleRate)).rounded())
        return readMono(startFrame: s, count: Int(max(0, e - s)))
    }

    public func readAllMono() -> [Float] {
        readMono(startFrame: 0, count: Int(frameCount))
    }

    @inline(__always)
    private static func sample(_ p: UnsafeRawPointer, bits: Int, isFloat: Bool) -> Float {
        switch (bits, isFloat) {
        case (16, false):
            return Float(Int16(littleEndian: p.loadUnaligned(as: Int16.self))) / 32768
        case (24, false):
            let b0 = Int32(p.load(fromByteOffset: 0, as: UInt8.self))
            let b1 = Int32(p.load(fromByteOffset: 1, as: UInt8.self))
            let b2 = Int32(Int8(bitPattern: p.load(fromByteOffset: 2, as: UInt8.self)))
            return Float((b2 << 16) | (b1 << 8) | b0) / 8_388_608
        case (32, false):
            return Float(Int32(littleEndian: p.loadUnaligned(as: Int32.self))) / 2_147_483_648
        case (32, true):
            return Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)))
        default:
            return 0
        }
    }
}

extension Data {
    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var v: T = 0
        let size = MemoryLayout<T>.size
        guard offset + size <= count else { return 0 }
        for i in 0..<size {
            v |= T(self[self.startIndex + offset + i]) << (8 * i)
        }
        return v
    }
}
