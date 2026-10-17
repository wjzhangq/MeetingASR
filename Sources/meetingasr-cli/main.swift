import Foundation
import MeetingASRCore
import MeetingASREngine

// meetingasr-cli：无界面执行完整识别流程，用于 M0 评估、批量处理与验证。

let usage = """
用法：
  meetingasr-cli recognize <音频文件> [--from 秒] [--to 秒] [--speakers N] [--keep-work]
  meetingasr-cli process <会议目录名>            重新识别未完成的会议
  meetingasr-cli sweep <会议目录列表文件>         参数扫描（M0 评估）
  meetingasr-cli list                           最近会议
  meetingasr-cli show <会议目录名>               打印 Markdown 逐字稿
  meetingasr-cli name <会议目录名> <S1> <姓名>    为说话人命名（姓名为空则清除）
  meetingasr-cli rename <会议目录名> <新标题>     修改会议标题（目录名不变）
  meetingasr-cli delete <会议目录名>             删除会议（不可恢复，人物库样本保留）
  meetingasr-cli people                         人物库

通用选项：
  --root <目录>     数据目录（默认 ~/Documents/MeetingASR）
  --models <目录>   模型目录（默认自动查找，或环境变量 MEETINGASR_MODELS）
  --threads N       推理线程数（默认按 CPU 核数）
  --threshold X     聚类阈值（默认 0.5）
  --match X         声纹匹配阈值（默认 0.6）
  --asr-model M     识别模型：paraformer（默认）| firered-ctc | firered-aed

段流水线参数：
  --vad-min-silence X       VAD 最小静音时长（秒，默认 0.4）
  --vad-max-speech X        VAD 最大段长（秒，默认 12）
  --merge-similarity X      簇合并阈值（默认 0.38）
  --min-cluster-sec X       小簇合并下限（秒，默认 3.0）
  --short-assign-sim X      短段归属阈值（默认 0.25）
  --mixed-valley X          混合段检测低谷（默认 0.3）
  --smooth-run-sec X        混合段标签平滑长度（秒，默认 1.5）
"""

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let layout = option("--root").map { StorageLayout(root: URL(fileURLWithPath: $0)) } ?? .default
let modelsDir = option("--models")
let threads = option("--threads").flatMap(Int.init) ?? AppSettings.load().recognition.numThreads
let threshold = option("--threshold").flatMap(Float.init)
let match = option("--match").flatMap(Double.init)
let from = option("--from").flatMap(Double.init)
let to = option("--to").flatMap(Double.init)
let speakers = option("--speakers").flatMap(Int.init)
let keepWork = flag("--keep-work")
let asrModel: AsrModelKind? = option("--asr-model").map { name in
    guard let k = AsrModelKind(cliName: name) else { fail("未知的识别模型：\(name)") }
    return k
}
// 段流水线参数（--mode 已废弃，只保留 segmentStream）
let vadMinSilence = option("--vad-min-silence").flatMap(Float.init)
let vadMaxSpeech = option("--vad-max-speech").flatMap(Float.init)
let mergeSimilarity = option("--merge-similarity").flatMap(Double.init)
let minClusterSec = option("--min-cluster-sec").flatMap(Double.init)
let shortAssignSim = option("--short-assign-sim").flatMap(Double.init)
let mixedValley = option("--mixed-valley").flatMap(Double.init)
let smoothRunSec = option("--smooth-run-sec").flatMap(Double.init)

guard let command = args.first else { fail(usage) }
args.removeFirst()

let store = MeetingStore(layout: layout)
let people = PeopleStore(layout: layout)

func makeProcessor() -> MeetingProcessor {
    guard let paths = modelsDir.map({ ModelPaths(root: URL(fileURLWithPath: $0)) }) ?? ModelPaths.locate() else {
        fail("找不到模型目录，请先运行 scripts/fetch-models.sh 或指定 --models")
    }
    var settings = AppSettings.load()
    if let asrModel { settings.recognition.asrModel = asrModel }
    settings.recognition.recognitionMode = .segmentStream  // 唯一模式

    // 段流水线参数（在引擎创建前应用，VAD 初始化需要它们）
    if let vadMinSilence { settings.recognition.segmentVAD.minSilenceDuration = vadMinSilence }
    if let vadMaxSpeech { settings.recognition.segmentVAD.maxSpeechDuration = vadMaxSpeech }
    if let mergeSimilarity { settings.recognition.segmentClustering.mergeSimilarity = mergeSimilarity }
    if let minClusterSec { settings.recognition.segmentClustering.minClusterSec = minClusterSec }
    if let shortAssignSim { settings.recognition.segmentClustering.shortAssignSimilarity = shortAssignSim }
    if let mixedValley { settings.recognition.segmentClustering.mixedValley = mixedValley }
    if let smoothRunSec { settings.recognition.segmentClustering.smoothRunSec = smoothRunSec }

    let kind = settings.recognition.asrModel
    if !paths.hasASR(kind) {
        let dir = paths.root.appendingPathComponent(kind.directory).path
        if asrModel != nil { fail("识别模型未安装：\(dir)（scripts/fetch-models.sh --with-asr \(kind.cliName)）") }
        FileHandle.standardError.write(Data("识别模型 \(kind.displayName) 未安装，改用 Paraformer\n".utf8))
    }
    let t0 = Date()
    let engines: EngineSet
    do { engines = try SherpaEngineFactory.make(paths: paths, numThreads: threads, asrModel: kind, provider: settings.recognition.inferenceProvider.providerString, vadConfig: settings.recognition.segmentVAD) } catch { fail("\(error)") }
    FileHandle.standardError.write(Data(String(format: "模型加载 %.1fs（%@，sherpa-onnx %@）\n", Date().timeIntervalSince(t0), engines.recognizer.modelName, SherpaEngineFactory.version).utf8))
    settings.recognition.numThreads = threads
    if let threshold { settings.recognition.clusterThreshold = threshold }
    if let match { settings.recognition.matchThreshold = match }

    var opts = ProcessingOptions(recognition: settings.recognition, hotwords: HotwordList.load())
    opts.deleteRawOnSuccess = !keepWork
    people.maxSamplesPerPerson = settings.recognition.maxSamplesPerPerson
    return MeetingProcessor(engines: engines, store: store, people: people, options: opts)
}

func run(_ m: MeetingPaths) {
    let proc = makeProcessor()
    let t0 = Date()
    var lastLine = ""
    var stageStart = (ProcessingStage.preprocess, t0)
    do {
        let t = try proc.process(m) { p in
            if p.stage != stageStart.0 {
                FileHandle.standardError.write(Data(String(format: "\r%@ 用时 %.1fs        \n", stageStart.0.displayName, Date().timeIntervalSince(stageStart.1)).utf8))
                stageStart = (p.stage, Date())
            }
            let line = String(format: "%@ %.1f%%（总 %d%%）", p.stage.displayName, p.stageFraction * 100, p.percent)
            if line != lastLine {
                lastLine = line
                FileHandle.standardError.write(Data("\r\(line)        ".utf8))
            }
        }
        let elapsed = Date().timeIntervalSince(t0)
        FileHandle.standardError.write(Data(String(format: "\n完成：音频 %.1fs，耗时 %.1fs（RTF %.3f），%d 位说话人，%d 段\n结果目录：%@\n",
                                                   t.durationSec, elapsed, elapsed / max(1, t.durationSec), t.speakers.count, t.segments.count, m.dir.path).utf8))
        print(TranscriptWriter.markdown(t))
    } catch {
        fail("\n识别失败：\(error)")
    }
}

func meeting(_ name: String?) -> MeetingPaths {
    guard let name else { fail(usage) }
    let m = layout.meeting(named: name)
    guard FileManager.default.fileExists(atPath: m.meta.path) else { fail("会议不存在：\(name)") }
    return m
}

switch command {
case "recognize":
    guard let path = args.first else { fail(usage) }
    let url = URL(fileURLWithPath: path)
    let range: ClosedRange<Double>? = (from != nil || to != nil) ? (from ?? 0)...(to ?? .greatestFiniteMagnitude) : nil
    do {
        let m = try MeetingFactory.createFileMeeting(source: url, range: range, expectedSpeakers: speakers, layout: layout)
        run(m)
    } catch {
        fail("无法打开音频：\(error)")
    }

case "process":
    run(meeting(args.first))

case "sweep":
    guard let listFile = args.first else { fail("用法：meetingasr-cli sweep <会议列表文件>\n文件格式：每行一个会议目录名，# 开头为注释") }
    guard FileManager.default.fileExists(atPath: listFile) else { fail("文件不存在：\(listFile)") }

    let meetingNames = (try? String(contentsOfFile: listFile, encoding: .utf8))?
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") } ?? []

    guard !meetingNames.isEmpty else { fail("列表文件为空") }

    // 参数网格
    let vadMinSilenceGrid: [Float] = [0.3, 0.4, 0.5]
    let mergeSimilarityGrid: [Double] = [0.36, 0.38, 0.40]
    let minClusterSecGrid: [Double] = [2.0, 3.0, 4.0]

    // 模型只加载一次，各网格点共用
    guard let sweepPaths = modelsDir.map({ ModelPaths(root: URL(fileURLWithPath: $0)) }) ?? ModelPaths.locate() else {
        fail("找不到模型目录，请先运行 scripts/fetch-models.sh 或指定 --models")
    }
    var baseSettings = AppSettings.load()
    if let asrModel { baseSettings.recognition.asrModel = asrModel }
    baseSettings.recognition.recognitionMode = .segmentStream
    baseSettings.recognition.numThreads = threads
    if let match { baseSettings.recognition.matchThreshold = match }

    let sweepEngines: EngineSet
    do {
        sweepEngines = try SherpaEngineFactory.make(
            paths: sweepPaths, numThreads: threads,
            asrModel: baseSettings.recognition.asrModel,
            provider: baseSettings.recognition.inferenceProvider.providerString)
    } catch { fail("\(error)") }

    let gridSize = vadMinSilenceGrid.count * mergeSimilarityGrid.count * minClusterSecGrid.count
    FileHandle.standardError.write(Data("参数扫描：\(meetingNames.count) 个会议 × \(gridSize) 组参数\n".utf8))
    print("meeting,vad_min_silence,merge_similarity,min_cluster_sec,duration_sec,processing_sec,num_speakers,num_segments")

    for name in meetingNames {
        let m = layout.meeting(named: name)
        guard FileManager.default.fileExists(atPath: m.meta.path) else {
            FileHandle.standardError.write(Data("跳过（会议不存在）：\(name)\n".utf8))
            continue
        }
        FileHandle.standardError.write(Data("\(name) ".utf8))

        for vadMS in vadMinSilenceGrid {
            for mergeSim in mergeSimilarityGrid {
                for minCluster in minClusterSecGrid {
                    var settings = baseSettings
                    settings.recognition.segmentVAD.minSilenceDuration = vadMS
                    settings.recognition.segmentClustering.mergeSimilarity = mergeSim
                    settings.recognition.segmentClustering.minClusterSec = minCluster

                    var opts = ProcessingOptions(recognition: settings.recognition, hotwords: HotwordList.load())
                    // 扫描要反复处理同一会议，必须保留原始音频
                    opts.deleteRawOnSuccess = false

                    let proc = MeetingProcessor(engines: sweepEngines, store: store, people: people, options: opts)
                    let t0 = Date()
                    do {
                        let t = try proc.process(m)
                        let elapsed = Date().timeIntervalSince(t0)
                        print("\(name),\(vadMS),\(mergeSim),\(minCluster),\(t.durationSec),\(String(format: "%.2f", elapsed)),\(t.speakers.count),\(t.segments.count)")
                        FileHandle.standardError.write(Data(".".utf8))
                    } catch {
                        FileHandle.standardError.write(Data("\n✗ \(name) [vad=\(vadMS) merge=\(mergeSim) min=\(minCluster)]：\(error)\n".utf8))
                    }
                }
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
    }
    FileHandle.standardError.write(Data("扫描完成\n".utf8))

case "list":
    for s in store.recentMeetings(limit: 20) {
        print("\(s.paths.name)\t\(s.status.rawValue)\t\(TranscriptWriter.clock(s.durationSec))")
    }

case "show":
    do { print(TranscriptWriter.markdown(try store.loadTranscript(meeting(args.first)))) } catch { fail("\(error)") }

case "name":
    guard args.count >= 2 else { fail(usage) }
    let m = meeting(args[0])
    let name = args.count >= 3 ? args[2...].joined(separator: " ") : ""
    do {
        let t = try SpeakerNaming(store: store, people: people).assign(name: name, to: args[1], in: m)
        for s in t.speakers { print("\(s.id)\t\(s.name)\t\(s.source.rawValue)") }
    } catch { fail("\(error)") }

case "rename":
    guard args.count >= 2 else { fail(usage) }
    do { print(try store.rename(meeting(args[0]), title: args[1...].joined(separator: " "))) } catch { fail("改名失败：\(error)") }

case "delete":
    let m = meeting(args.first)
    do { try store.delete(m); print("已删除：\(m.name)") } catch { fail("删除失败：\(error)") }

case "people":
    for p in people.people {
        print("\(p.id)\t\(p.name)\t样本 \(p.samples.count)")
    }

default:
    fail(usage)
}
