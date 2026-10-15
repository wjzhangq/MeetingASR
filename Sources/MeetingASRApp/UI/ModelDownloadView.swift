import SwiftUI

/// 模型下载视图：首次启动时显示。
struct ModelDownloadView: View {
    @StateObject private var downloader = ModelDownloader()
    @State private var showError = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("首次启动需要下载 AI 模型")
                .font(.title2)
                .fontWeight(.semibold)

            Text("模型大小约 550 MB，将下载到：")
                .foregroundColor(.secondary)

            if let modelDir = ModelDownloader.userModelsDirectory() {
                Text(modelDir.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .textSelection(.enabled)
            }

            Spacer().frame(height: 20)

            // 状态显示
            Group {
                switch downloader.state {
                case .idle:
                    Button("开始下载") {
                        Task {
                            // 开发模式：检查环境变量指定的本地归档
                            if let localPath = ProcessInfo.processInfo.environment["LOCAL_MODEL_ARCHIVE"],
                               !localPath.isEmpty {
                                let localURL = URL(fileURLWithPath: localPath)
                                await downloader.downloadModels(localArchive: localURL)
                            } else {
                                await downloader.downloadModels()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                case .downloading, .extracting, .verifying:
                    VStack(spacing: 12) {
                        ProgressView(value: downloader.progress)
                            .frame(width: 300)

                        Text(downloader.statusMessage)
                            .foregroundColor(.secondary)

                        if case .downloading = downloader.state {
                            Text("\(Int(downloader.progress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("取消") {
                            downloader.cancel()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }

                case .completed:
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)

                        Text("下载完成")
                            .font(.headline)

                        Button("继续") {
                            NSApplication.shared.keyWindow?.close()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                case .failed(let error):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)

                        Text("下载失败")
                            .font(.headline)

                        Text(error.localizedDescription)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        HStack(spacing: 12) {
                            Button("重试") {
                                downloader.cancel()
                                Task {
                                    await downloader.downloadModels()
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("退出") {
                                NSApplication.shared.terminate(nil)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Spacer()

            // 底部提示
            VStack(spacing: 4) {
                Text("模型来自 sherpa-onnx 开源项目")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text("下载完成后，模型将永久保存在本地")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(30)
        .frame(width: 500, height: 400)
    }
}

#Preview {
    ModelDownloadView()
}
