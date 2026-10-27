import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("微信") {
                TextField("WeChat.app 路径", text: $model.wechatPath)
                HStack {
                    Button("恢复默认") {
                        model.wechatPath = "/Applications/WeChat.app"
                        Task { await model.refresh() }
                    }
                    Button("重新检测") {
                        Task { await model.refresh() }
                    }
                    Spacer()
                    if let info = model.info {
                        Text(info.displayVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("运行时") {
                LabeledContent("Python", value: model.pythonURL?.path ?? "未找到")
                LabeledContent("tools", value: model.toolsDir?.path ?? "未找到")
                LabeledContent("login dylib", value: model.bundledDylibURL?.path ?? "未构建")
                Text("打包版会把这些文件放在 ExtraWeChat.app/Contents/Resources 下。开发时可用 EXTRAWECHAT_TOOLS_DIR 指向仓库 tools 目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
