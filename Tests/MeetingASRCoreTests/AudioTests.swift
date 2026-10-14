import XCTest
@testable import MeetingASRCore

final class AudioTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("masr-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func sine(freq: Double, rate: Int, seconds: Double, amp: Float = 0.5) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { amp * Float(sin(2 * .pi * freq * Double($0) / Double(rate))) }
    }

    /// 通过过零点估计频率
    func estimateFreq(_ x: [Float], rate: Int) -> Double {
        var crossings = 0
        for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(x.count) / Double(rate))
    }

    func testWavRoundTripInt16AndFloat() throws {
        let s = sine(freq: 440, rate: 16_000, seconds: 1)
        for fmt in [WavSampleFormat.int16, .float32] {
            let url = tmp.appendingPathComponent("a-\(fmt).wav")
            try WavWriter.writeMono(s, sampleRate: 16_000, to: url, format: fmt)
            let r = try WavReader(url: url)
            XCTAssertEqual(r.sampleRate, 16_000)
            XCTAssertEqual(r.frameCount, 16_000)
            let back = r.readAllMono()
            for i in stride(from: 0, to: s.count, by: 97) {
                XCTAssertEqual(back[i], s[i], accuracy: 1e-3)
            }
            let part = r.readMono(from: 0.5, to: 0.6)
            XCTAssertEqual(part.count, 1600)
            XCTAssertEqual(part[0], s[8000], accuracy: 1e-3)
        }
    }

    func testStereoDownmixAndTruncatedHeader() throws {
        let url = tmp.appendingPathComponent("st.wav")
        let w = try WavWriter(url: url, sampleRate: 48_000, channels: 2, format: .float32)
        var inter: [Float] = []
        for _ in 0..<48_000 { inter += [0.2, 0.6] }
        w.write(inter)
        // 模拟异常退出：不调用 close，头部长度可能未回填
        w.updateHeader()
        w.write(inter) // 第二秒写入后未更新头部
        let r = try WavReader(url: url)
        XCTAssertEqual(r.channels, 2)
        XCTAssertEqual(r.readMono(startFrame: 10, count: 1)[0], 0.4, accuracy: 1e-6)
        // 头部声明 1 秒，但 data 是最后一个块，以实际文件大小为准
        XCTAssertGreaterThanOrEqual(r.frameCount, 48_000)
        try w.close()
        XCTAssertEqual(try WavReader(url: url).frameCount, 96_000)
    }

    func testWriteSilence() throws {
        let url = tmp.appendingPathComponent("sil.wav")
        let w = try WavWriter(url: url, sampleRate: 16_000)
        w.writeSilence(frames: 40_000)
        try w.close()
        let r = try WavReader(url: url)
        XCTAssertEqual(r.frameCount, 40_000)
        XCTAssertEqual(SignalStats.rms(r.readAllMono()), 0)
    }

    func testResamplerPreservesFrequencyAndLength() {
        let x = sine(freq: 1000, rate: 48_000, seconds: 2)
        // 分块喂入，检验流式结果与一次性结果一致
        let r = Resampler(inputRate: 48_000, outputRate: 16_000)
        var y: [Float] = []
        var i = 0
        while i < x.count {
            y += r.process(Array(x[i..<min(x.count, i + 4_801)]))
            i += 4_801
        }
        y += r.flush()
        XCTAssertEqual(y.count, 32_000)
        XCTAssertEqual(estimateFreq(Array(y[1000..<31000]), rate: 16_000), 1000, accuracy: 5)
        XCTAssertEqual(SignalStats.rms(Array(y[1000..<31000])), 0.5 / sqrt(2), accuracy: 0.01)
        let once = Resampler.resample(x, from: 48_000, to: 16_000)
        XCTAssertEqual(once.count, y.count)
        XCTAssertEqual(once[12_345], y[12_345], accuracy: 1e-5)
    }

    func testResamplerRejectsAliasing() {
        // 12kHz 在 16k 输出中会混叠，应被滤除
        let x = sine(freq: 12_000, rate: 48_000, seconds: 1)
        let y = Resampler.resample(x, from: 48_000, to: 16_000)
        XCTAssertLessThan(SignalStats.rms(Array(y[500..<15_500])), 0.01)
    }

    func testResample44100() {
        let x = sine(freq: 300, rate: 44_100, seconds: 1)
        let y = Resampler.resample(x, from: 44_100, to: 16_000)
        XCTAssertEqual(y.count, 16_000)
        XCTAssertEqual(estimateFreq(Array(y[500..<15_500]), rate: 16_000), 300, accuracy: 3)
    }

    func testPreprocessNormalizesAndRanges() throws {
        let src = tmp.appendingPathComponent("src.wav")
        try WavWriter.writeMono(sine(freq: 200, rate: 48_000, seconds: 4, amp: 0.01), sampleRate: 48_000, to: src)
        let out = tmp.appendingPathComponent("out.wav")
        let res = try Preprocessor.process(source: WavReader(url: src), range: 1...3, output: out)
        XCTAssertEqual(res.durationSec, 2, accuracy: 0.01)
        let y = try WavReader(url: out).readAllMono()
        XCTAssertEqual(y.count, 32_000)
        // 0.01 幅度 → RMS 0.007，增益被限制在 10 倍
        XCTAssertEqual(res.gain, 10, accuracy: 0.2)
        XCTAssertEqual(SignalStats.rms(Array(y[1000..<31000])), 0.0707, accuracy: 0.005)
    }

    func testPreprocessLimitsPeak() throws {
        let src = tmp.appendingPathComponent("loud.wav")
        try WavWriter.writeMono(sine(freq: 200, rate: 16_000, seconds: 1, amp: 0.95), sampleRate: 16_000, to: src)
        let out = tmp.appendingPathComponent("loud-out.wav")
        _ = try Preprocessor.process(source: WavReader(url: src), output: out)
        let y = try WavReader(url: out).readAllMono()
        XCTAssertLessThanOrEqual(y.map { abs($0) }.max()!, 1.0)
    }

    func testCorrelation() {
        let a = sine(freq: 300, rate: 16_000, seconds: 0.5)
        var b = [Float](repeating: 0, count: 40) + a.map { $0 * 0.3 }
        b.removeLast(40)
        XCTAssertGreaterThan(SignalStats.maxNormalizedCorrelation(a, b, maxLag: 80, step: 2), 0.95)
        let noise = (0..<a.count).map { _ in Float.random(in: -0.5...0.5) }
        XCTAssertLessThan(SignalStats.maxNormalizedCorrelation(a, noise, maxLag: 80, step: 2), 0.3)
    }
}
