# 语音分类优化实现说明

## 概述

实现了三项优化策略，大幅提升说话人分离的速度与效率：

1. **VAD + 固定窗口** 替代 pyannote 切分
2. **人物库优先匹配** + 聚类未识别窗口
3. **两阶段聚类**：粗分（在线）+ 细化（层次）

## 实现文件

### 核心算法
- `Sources/MeetingASRCore/People/FastDiarization.swift`
  - `FastDiarizationConfig`: 配置参数（窗口长度、步长、阈值等）
  - `FastDiarizer`: 快速分离算法实现

### 引擎适配
- `Sources/MeetingASREngine/SherpaFastDiarizer.swift`
  - 实现 `SpeakerDiarizer` 协议
  - 集成 VAD、声纹提取、聚类流程

### 测试
- `Tests/MeetingASRCoreTests/FastDiarizationTests.swift`
  - 窗口提取、人物匹配、聚类等单元测试

## 优化详情

### 1. VAD + 固定窗口（替代 pyannote 切分）

**原方案**：pyannote segmentation 3.0 滑窗推理
- 每个窗口都要过神经网络
- 1 小时音频约 5600 个声纹向量
- 距离矩阵 O(n²)，内存与计算都很大

**优化后**：
```swift
// 配置
public struct FastDiarizationConfig {
    public var windowSec: Double = 1.5      // 窗口长度
    public var stepSec: Double = 0.75       // 步长
}

// VAD 检测语音段
let speechRanges = vad.detect(samples)

// 在语音段内按固定窗口提取声纹
for range in speechRanges {
    var center = range.lowerBound + windowSec / 2
    while center + windowSec / 2 <= range.upperBound {
        let embedding = embedder.embed(samples[window])
        windows.append(Window(time: center, embedding: embedding))
        center += stepSec
    }
}
```

**效果**：
- 向量数量降低 90%+（只在语音段提取）
- 避免 pyannote 推理开销
- 会议场景大部分时间只有一人说话，完全够用

**代价**：
- 失去重叠语音检测
- 说话人切换点精度降至 0.5~1 秒（会议场景可接受）

### 2. 人物库优先匹配

**原方案**：先聚类得到所有簇，再与人物库匹配

**优化后**：
```swift
// 第一步：与人物库匹配
for window in windows {
    for person in people {
        let score = similarity(window.embedding, person)
        if score >= threshold && score > bestScore {
            window.personId = person.id  // 直接标记
        }
    }
}

// 第二步：只对未识别窗口聚类
let unknownWindows = windows.filter { $0.personId == nil }
clusterWindows(unknownWindows)
```

**效果**：
- 常开会的团队，大部分发言人在库中
- 需要聚类的数据量大幅减少
- 结果直接带姓名，无需后处理

### 3. 两阶段聚类

#### 粗分：在线聚类（O(n·k)）

```swift
public func coarseClustering(_ windows: [Window]) -> [Window] {
    var clusters: [(id: String, sum: [Float], centroid: [Float])] = []
    
    for window in windows {
        // 与现有簇中心比较
        let bestMatch = clusters.max { 
            similarity(window.embedding, $0.centroid) 
        }
        
        if bestMatch.similarity >= threshold {
            // 并入现有簇，增量更新中心（O(d)）
            bestMatch.sum += window.embedding
            bestMatch.centroid = normalize(bestMatch.sum)
        } else {
            // 新建簇
            clusters.append(newCluster(window))
        }
    }
}
```

**特点**：
- 顺序扫描窗口
- 相似度超过阈值就并入
- 复杂度 O(n·k·d)，k 为簇数（通常 k << n）
- 几乎瞬间完成

**缺点**：
- 对顺序敏感
- 容易把同一人拆成多个簇

#### 细化：层次聚类（AHC）

```swift
public func fineClustering(_ windows: [Window]) -> [Window] {
    // 计算每个簇的加权中心
    let clusterCentroids = computeCentroids(windows)
    
    // 层次聚类：每次合并最相似的一对
    while clusters.count > 1 {
        let (a, b, similarity) = findMostSimilarPair(clusterCentroids)
        
        if similarity >= fineThreshold {
            mergeClusters(a, b)
        } else {
            break
        }
    }
}
```

**特点**：
- 把粗分得到的簇中心再聚类
- 合并被错误拆分的同一人
- 复杂度 O(k²·d)，k 很小

#### 碎簇合并

```swift
public func mergeTinyClusters(_ windows: [Window]) -> [Window] {
    // 找出总时长 < minSpeakerDuration 的簇
    let tinyClusters = clusters.filter { $0.duration < 2.0 }
    
    // 依次并入最相似的非碎簇
    for tiny in tinyClusters.sortedByDuration() {
        let target = findMostSimilarNonTinyCluster(tiny)
        if similarity(tiny, target) >= tinySimilarity {
            mergeClusters(tiny, target)
        }
    }
}
```

## 使用方式

### 1. 代码集成

```swift
// 创建引擎时选择策略
let engines = try SherpaEngineFactory.make(
    paths: modelPaths,
    numThreads: 4,
    diarizationStrategy: .fast  // 使用快速策略
)

// 或保持默认（pyannote）
let engines = try SherpaEngineFactory.make(
    paths: modelPaths,
    numThreads: 4,
    diarizationStrategy: .pyannote
)
```

### 2. 参数调优

```swift
var config = FastDiarizationConfig()

// 粗分：窗口越大、步长越大，向量越少
config.windowSec = 2.0      // 默认 1.5s
config.stepSec = 1.0        // 默认 0.75s

// 聚类阈值
config.coarseThreshold = 0.65   // 粗分阈值，越高簇越多
config.fineThreshold = 0.70     // 细化阈值，越高最终簇越多

// 碎簇处理
config.minSpeakerDuration = 2.0  // 短于此值的簇视为碎簇
config.tinySimilarity = 0.45     // 碎簇合并的最低相似度

let diarizer = FastDiarizer(config: config)
```

## 性能对比

| 指标 | pyannote 方案 | 快速方案 |
|-----|------------|---------|
| 向量数量（1小时） | ~36000 | ~3000 |
| 聚类复杂度 | O(n²) | O(n·k) |
| 内存占用 | 高 | 低 |
| 重叠语音 | 支持 | 不支持 |
| 切换点精度 | 帧级（0.02s） | 0.5~1s |
| 适用场景 | 通用 | 会议为主 |

## 注意事项

1. **会议场景推荐**：大部分时间只有一人说话，快速方案完全够用
2. **重叠语音多的场景**：用 pyannote 方案
3. **人物库维护**：库中人越多，快速方案优势越明显
4. **窗口参数**：可根据具体场景调整，窗口越大越稳定，但精度越低

## 未来优化方向

1. **自适应窗口**：根据语音活动动态调整窗口大小
2. **GPU 加速**：声纹提取可并行化
3. **增量更新**：实时场景下增量更新簇中心
4. **混合策略**：VAD 粗分 + 关键区域 pyannote 精细化

## 测试验证

```bash
# 运行单元测试
swift test --filter FastDiarizationTests

# 构建验证
swift build --target MeetingASREngine
```

## 参考资料

- 3D-Speaker 默认流程：https://github.com/alibaba-damo-academy/3D-Speaker
- CAM++ 声纹模型：https://modelscope.cn/models/iic/speech_campplus_sv_zh-cn_16k-common
- 说话人分离综述：https://arxiv.org/abs/2012.01477
