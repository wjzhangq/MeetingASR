# 录音模式场景化实现总结

## 📋 需求
用户希望在开始录音时，能够根据会议类型选择合适的录音模式：
- **单人会议**：录制所有音频（麦克风）
- **多人会议**：仅录制会议软件（Teams 等）

## ✅ 实现方案
采用**方案 A**：优化现有 UI 的场景描述，无需改动录音逻辑。

## 🔧 修改内容

### 1. 更新采集源选项文案
**文件**: `Sources/MeetingASRCore/Models/AppSettings.swift:12-18`

**修改前**:
```swift
case .micOnly: return "仅麦克风"
case .appOnly: return "仅会议软件"
case .both: return "两者"
```

**修改后**:
```swift
case .micOnly: return "仅麦克风（单人会议）"
case .appOnly: return "仅会议软件（多人会议）"
case .both: return "麦克风 + 会议软件"
```

### 2. 在设置界面添加场景说明
**文件**: `Sources/MeetingASRApp/UI/SettingsView.swift:123-135`

**添加内容**:
```swift
Section("采集源") {
    Picker("录制", selection: ...) {
        ForEach(CaptureSource.allCases, id: \.self) { Text($0.displayName).tag($0) }
    }
    .pickerStyle(.segmented)
    
    // 场景说明
    VStack(alignment: .leading, spacing: 4) {
        Text("• 仅麦克风：录制你的声音，适合单人演示、讲座或播客").font(.caption).foregroundStyle(.secondary)
        Text("• 仅会议软件：录制会议中所有人的声音，适合多人远程会议").font(.caption).foregroundStyle(.secondary)
        Text("• 麦克风 + 会议软件：同时录制两路音轨，可分离本地和远程声音").font(.caption).foregroundStyle(.secondary)
    }
}
```

## 📊 用户体验改进

### 改进前
用户在设置中看到：
- ⚪ 仅麦克风
- ⚪ 仅会议软件  
- ⚪ 两者

→ **不清楚**每个选项的适用场景

### 改进后
用户在设置中看到：
- ⚪ 仅麦克风（单人会议）
- ⚪ 仅会议软件（多人会议）
- ⚪ 麦克风 + 会议软件

并且下方有详细的使用场景说明：
- • 仅麦克风：录制你的声音，适合单人演示、讲座或播客
- • 仅会议软件：录制会议中所有人的声音，适合多人远程会议
- • 麦克风 + 会议软件：同时录制两路音轨，可分离本地和远程声音

→ **一目了然**，用户可以快速选择适合的模式

## 🏗️ 构建说明

由于使用 CommandLineTools（缺少 SwiftUIMacros 插件），命令行构建会失败。

**推荐构建方式**：
```bash
# 在 Xcode 中打开并构建应用
open App/MeetingASR.xcodeproj
```

或使用构建脚本：
```bash
./scripts/build-app.sh
```

## ✨ 优点

1. **实现简单**：仅修改 UI 文案和添加说明文字
2. **无需改动录音逻辑**：利用现有的 `CaptureSource` 枚举
3. **用户友好**：清楚地说明每个选项的适用场景
4. **向后兼容**：不影响现有用户的设置

## 📝 测试建议

1. 打开应用设置
2. 进入"采集"标签页
3. 验证采集源选项显示新的文案
4. 验证场景说明正确显示
5. 切换不同选项，确认录音行为符合预期

## 🔄 未来可能的增强

如果用户反馈需要更灵活的控制，可以考虑：
- 在菜单栏添加快速切换录音模式的选项
- 添加录音预设功能
- 在开始录音时提供模式选择对话框
