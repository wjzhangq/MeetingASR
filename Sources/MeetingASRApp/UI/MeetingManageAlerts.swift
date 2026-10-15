import MeetingASRCore
import SwiftUI

/// 要改名或删除的会议。
struct MeetingTarget: Identifiable, Equatable {
    let name: String
    let title: String
    var id: String { name }
}

extension View {
    /// 会议改名 / 删除确认对话框。`renaming` / `deleting` 非 nil 时弹出。
    func meetingManageAlerts(renaming: Binding<MeetingTarget?>, deleting: Binding<MeetingTarget?>, onRenamed: @escaping () -> Void = {}) -> some View {
        modifier(MeetingManageAlerts(renaming: renaming, deleting: deleting, onRenamed: onRenamed))
    }
}

private struct MeetingManageAlerts: ViewModifier {
    @Binding var renaming: MeetingTarget?
    @Binding var deleting: MeetingTarget?
    var onRenamed: () -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: renaming) { _, r in if let r { text = r.title } }
            .alert("重命名会议", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("会议标题", text: $text)
                Button("取消", role: .cancel) { renaming = nil }
                Button("确定") {
                    if let r = renaming { AppState.shared.renameMeeting(r.name, to: text) }
                    renaming = nil
                    onRenamed()
                }
            } message: {
                Text("同时更新逐字稿（json / md / srt）中的标题，会议目录不变。")
            }
            .alert("删除会议“\(deleting?.title ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除", role: .destructive) {
                    if let d = deleting { AppState.shared.deleteMeeting(d.name) }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: {
                Text("将永久删除该会议的逐字稿、说话人特征片段及未识别的原始录音，无法恢复。人物库中已保存的声纹样本不受影响。")
            }
    }
}
