import XCTest
@testable import MeetingASRCore

// MARK: - Mock StreamingVAD

private final class MockStreamingVAD: StreamingVAD {
    private var samples: [Float] = []
    private var segments: [ClosedRange<Double>] = []
    private let sampleRate: Int
    private let energyThreshold: Float
    
    init(sampleRate: Int = 16_000, energyThreshold: Float = 0.01) {
        self.sampleRate = sampleRate
        self.energyThreshold = energyThreshold
    }
    
    func accept(_ samples: [Float]) {
        self.samples.append(contentsOf: samples)
        detectSegments()
    }
    
    func next() -> ClosedRange<Double>? {
        guard !segments.isEmpty else { return nil }
        return segments.removeFirst()
    }
    
    func flush() {
        if !samples.isEmpty {
            detectSegments(forceLast: true)
        }
    }
    
    func reset() {
        samples.removeAll()
        segments.removeAll()
    }
    
    private func detectSegments(forceLast: Bool = false) {
        let frameSize = 8000
        var i = 0
        var currentStart: Double?
        
        while i + frameSize <= samples.count || (forceLast && i < samples.count) {
            let end = min(samples.count, i + frameSize)
            let frame = Array(samples[i..<end])
            let rms = SignalStats.rms(frame)
            let t = Double(i) / Double(sampleRate)
            
            if rms > energyThreshold {
                if currentStart == nil {
                    currentStart = t
                }
            } else if let start = currentStart {
                segments.append(start...t)
                currentStart = nil
            }
            
            i += frameSize
        }
        
        if forceLast, let start = currentStart {
            segments.append(start...(Double(samples.count) / Double(sampleRate)))
        }
    }
}

// MARK: - Tests

final class SegmentVADTests: XCTestCase {
    func testBasicSegmentation() {
        let mockVAD = MockStreamingVAD()
        let segmenter = SegmentVAD(
            vad: mockVAD,
            track: .mic,
            config: SegmentVADConfig()
        )
        
        // 送入 1 秒语音 + 1 秒静音 + 1 秒语音
        let speech1 = [Float](repeating: 0.1, count: 16_000)
        let silence = [Float](repeating: 0, count: 16_000)
        let speech2 = [Float](repeating: 0.1, count: 16_000)
        
        segmenter.accept(speech1)
        segmenter.accept(silence)
        segmenter.accept(speech2)
        segmenter.flush()
        
        let segments = segmenter.drainSegments()
        
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].track, .mic)
        XCTAssertEqual(segments[0].id, 0)
        XCTAssertEqual(segments[1].id, 1)
    }
    
    func testPadding() {
        let mockVAD = MockStreamingVAD()
        var config = SegmentVADConfig()
        config.padBefore = 0.15
        config.padAfter = 0.1
        
        let segmenter = SegmentVAD(vad: mockVAD, track: .system, config: config)
        
        // 送入前 0.5 秒静音，然后 1 秒语音
        let silence = [Float](repeating: 0, count: 8_000)
        let speech = [Float](repeating: 0.1, count: 16_000)
        
        segmenter.accept(silence)
        segmenter.accept(speech)
        segmenter.flush()
        
        let segments = segmenter.drainSegments()
        XCTAssertEqual(segments.count, 1)
        
        let seg = segments[0]
        // VAD 检测到语音从 0.5s 开始
        XCTAssertEqual(seg.speechStart, 0.5, accuracy: 0.01)
        // 补边后 start 应该是 0.5 - 0.15 = 0.35
        XCTAssertEqual(seg.start, 0.35, accuracy: 0.01)
        // 补边后 end 应该是 speechEnd + 0.1
        XCTAssertGreaterThan(seg.end, seg.speechEnd)
    }
    
    func testPaddingClampedToZero() {
        let mockVAD = MockStreamingVAD()
        var config = SegmentVADConfig()
        config.padBefore = 1.0  // 很大的前补边
        
        let segmenter = SegmentVAD(vad: mockVAD, track: .mic, config: config)
        
        // 立即送入语音
        let speech = [Float](repeating: 0.1, count: 16_000)
        segmenter.accept(speech)
        segmenter.flush()
        
        let segments = segmenter.drainSegments()
        XCTAssertEqual(segments.count, 1)
        
        // start 应该被裁到 0
        XCTAssertEqual(segments[0].start, 0)
    }
    
    func testFlushEmitsLastSegment() {
        let mockVAD = MockStreamingVAD()
        let segmenter = SegmentVAD(vad: mockVAD, track: .mic, config: SegmentVADConfig())
        
        let speech = [Float](repeating: 0.1, count: 16_000)
        segmenter.accept(speech)
        
        // flush 前应该没有段
        XCTAssertNil(segmenter.nextSegment())
        
        segmenter.flush()
        
        // flush 后应该有一个段
        let seg = segmenter.nextSegment()
        XCTAssertNotNil(seg)
    }
    
    func testShortSegmentFlagging() {
        let mockVAD = MockStreamingVAD()
        let segmenter = SegmentVAD(vad: mockVAD, track: .mic, config: SegmentVADConfig())
        
        // 0.5 秒短语音
        let shortSpeech = [Float](repeating: 0.1, count: 8_000)
        segmenter.accept(shortSpeech)
        segmenter.flush()
        
        let segments = segmenter.drainSegments()
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThan(segments[0].speechDuration, 1.0)
    }
    
    func testReset() {
        let mockVAD = MockStreamingVAD()
        let segmenter = SegmentVAD(vad: mockVAD, track: .mic, config: SegmentVADConfig())
        
        let speech = [Float](repeating: 0.1, count: 16_000)
        segmenter.accept(speech)
        segmenter.flush()
        
        XCTAssertEqual(segmenter.drainSegments().count, 1)
        
        segmenter.reset()
        
        // reset 后再送入应该从 id=0 重新开始
        segmenter.accept(speech)
        segmenter.flush()
        let segments = segmenter.drainSegments()
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].id, 0)
    }
}
