// swift-tools-version:5.9
import PackageDescription

// sherpa-onnx 预编译库由 scripts/fetch-sherpa-onnx.sh 下载到 Vendor/sherpa-onnx/{include,lib}。
let vendorLib = "Vendor/sherpa-onnx/lib"

// rpath：.app 内为 Contents/Frameworks；开发时指回 Vendor。
// 开发期产物目录随工具链不同：旧版 SwiftPM 为 .build/<triple>/<config>/（上溯 3 级到仓库根），
// 新版（Swift 6.x 的 build-system）为 .build/out/Products/<Config>/（上溯 4 级），两条都加上。
let sherpaLinker: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(vendorLib)",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../\(vendorLib)",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../\(vendorLib)",
    ], .when(platforms: [.macOS])),
    .unsafeFlags([
        "-L\(vendorLib)",
        "-Xlinker", "-rpath", "-Xlinker", "$ORIGIN/../lib",
        "-Xlinker", "-rpath", "-Xlinker", "$ORIGIN/../../../\(vendorLib)",
        "-Xlinker", "-rpath", "-Xlinker", "$ORIGIN/../../../../\(vendorLib)",
    ], .when(platforms: [.linux])),
]

var products: [Product] = [
    .library(name: "MeetingASRCore", targets: ["MeetingASRCore"]),
    .executable(name: "meetingasr-cli", targets: ["meetingasr-cli"]),
]

var targets: [Target] = [
    .systemLibrary(name: "SherpaOnnxC", path: "Sources/SherpaOnnxC"),
    // 上游 swift-api-examples/SherpaOnnx.swift（Apache-2.0），版本与 Vendor 中的库一致。
    .target(name: "SherpaOnnx", dependencies: ["SherpaOnnxC"], path: "Sources/SherpaOnnx"),
    // 与平台无关的业务逻辑：数据结构、分段、匹配、人物库、输出、流水线编排。
    .target(name: "MeetingASRCore", path: "Sources/MeetingASRCore"),
    // sherpa-onnx 推理引擎适配（ASR / 分离 / 声纹 / VAD / 标点）。
    .target(
        name: "MeetingASREngine",
        dependencies: ["MeetingASRCore", "SherpaOnnx"],
        path: "Sources/MeetingASREngine",
        linkerSettings: sherpaLinker
    ),
    // 命令行：识别音频文件，用于 M0 评估与无界面验证。
    .executableTarget(
        name: "meetingasr-cli",
        dependencies: ["MeetingASRCore", "MeetingASREngine"],
        path: "Sources/meetingasr-cli"
    ),
    .testTarget(
        name: "MeetingASRCoreTests",
        dependencies: ["MeetingASRCore"],
        path: "Tests/MeetingASRCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "MeetingASR", targets: ["MeetingASRApp"]))
targets.append(
    .executableTarget(
        name: "MeetingASRApp",
        dependencies: ["MeetingASRCore", "MeetingASREngine"],
        path: "Sources/MeetingASRApp",
        linkerSettings: [
            .linkedFramework("CoreAudio"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("ServiceManagement"),
            .linkedFramework("Carbon"),
        ]
    )
)
#endif

let package = Package(
    name: "MeetingASR",
    platforms: [.macOS("14.2")], // Core Audio Process Tap 需要 14.2
    products: products,
    targets: targets
)
