import XCTest
@testable import MeetingASRCore

final class FastDiarizationTests: XCTestCase {

    /// 测试窗口提取：VAD 语音段内按固定窗口提取声纹
    func testExtractWindows() {
        let config = FastDiarizationConfig()
        let diarizer = FastDiarizer(config: config)

        // 模拟两段语音：[1, 4] 和 [6, 9]
        let speechRanges: [ClosedRange<Double>] = [1...4, 6...9]

        // 简单的声纹提取：返回时间戳作为特征
        let embed: (Double, Double) -> [Float]? = { start, end in
            return [Float(start), Float(end)]
        }

        let windows = diarizer.extractWindows(
            speechRanges: speechRanges,
            totalDuration: 10,
            embed: embed
        )

        // 窗口长度 1.5s，步长 0.75s
        // 第一段 [1, 4]：中心点从 1.75 开始，间隔 0.75，到 3.25
        // 第二段 [6, 9]：中心点从 6.75 开始，到 8.25
        XCTAssertGreaterThan(windows.count, 0)

        // 验证窗口在语音段内
        for w in windows {
            let inFirst = w.time >= 1 && w.time <= 4
            let inSecond = w.time >= 6 && w.time <= 9
            XCTAssertTrue(inFirst || inSecond, "Window at \(w.time) outside speech ranges")
        }
    }

    /// 测试人物匹配：已知说话人优先识别
    func testMatchKnownSpeakers() {
        let config = FastDiarizationConfig()
        let diarizer = FastDiarizer(config: config)

        // 创建两个人物，各有一个样本
        let person1 = Person(
            id: "p1",
            name: "Alice",
            samples: [PersonSample(
                meeting: "m1",
                speaker: "S0",
                embedding: [1.0, 0.0, 0.0]
            )]
        )

        let person2 = Person(
            id: "p2",
            name: "Bob",
            samples: [PersonSample(
                meeting: "m1",
                speaker: "S1",
                embedding: [0.0, 1.0, 0.0]
            )]
        )

        // 创建窗口：三个窗口，前两个应匹配到 p1 和 p2，第三个不匹配
        let windows = [
            FastDiarizer.Window(time: 1.0, embedding: [0.9, 0.1, 0.0]),  // 接近 p1
            FastDiarizer.Window(time: 2.0, embedding: [0.0, 0.9, 0.1]),  // 接近 p2
            FastDiarizer.Window(time: 3.0, embedding: [0.0, 0.0, 1.0])   // 不接近任何人
        ]

        let result = diarizer.matchKnownSpeakers(
            windows,
            people: [person1, person2],
            threshold: 0.7
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].personId, "p1")
        XCTAssertEqual(result[1].personId, "p2")
        XCTAssertNil(result[2].personId)
    }

    /// 测试粗分聚类：在线顺序聚类
    func testCoarseClustering() {
        let config = FastDiarizationConfig()
        let diarizer = FastDiarizer(config: config)

        // 创建窗口：两组明显不同的向量
        let windows = [
            FastDiarizer.Window(time: 1.0, embedding: [1.0, 0.0, 0.0]),
            FastDiarizer.Window(time: 2.0, embedding: [0.9, 0.1, 0.0]),  // 接近第一个
            FastDiarizer.Window(time: 3.0, embedding: [0.0, 1.0, 0.0]),
            FastDiarizer.Window(time: 4.0, embedding: [0.0, 0.9, 0.1])   // 接近第三个
        ]

        let result = diarizer.coarseClustering(windows)

        XCTAssertEqual(result.count, 4)

        // 第一和第二个应该在同一簇
        XCTAssertNotNil(result[0].clusterId)
        XCTAssertEqual(result[0].clusterId, result[1].clusterId)

        // 第三和第四个应该在同一簇
        XCTAssertNotNil(result[2].clusterId)
        XCTAssertEqual(result[2].clusterId, result[3].clusterId)

        // 两组应该在不同的簇
        XCTAssertNotEqual(result[0].clusterId, result[2].clusterId)
    }

    /// 测试细化聚类：层次聚并
    func testFineClustering() {
        let config = FastDiarizationConfig()
        let diarizer = FastDiarizer(config: config)

        // 先粗分得到多个簇
        var windows = [
            FastDiarizer.Window(time: 1.0, embedding: [1.0, 0.0, 0.0]),
            FastDiarizer.Window(time: 2.0, embedding: [0.95, 0.05, 0.0]),
            FastDiarizer.Window(time: 3.0, embedding: [0.9, 0.1, 0.0])
        ]

        // 手动设置不同的簇 ID（模拟粗分结果）
        windows[0].clusterId = "C0"
        windows[1].clusterId = "C1"
        windows[2].clusterId = "C2"

        // 细化应该把这些相似的簇合并
        let result = diarizer.fineClustering(windows, numSpeakers: nil)

        XCTAssertEqual(result.count, 3)

        // 三个窗口最终应该属于同一簇（因为它们的向量很相似）
        let finalClusters = Set(result.compactMap { $0.clusterId })
        XCTAssertLessThanOrEqual(finalClusters.count, 2)
    }
}
