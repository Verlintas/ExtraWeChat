// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("外观") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(AppTheme.allCases) { theme in
                        themeCard(theme)
                    }
                }
                .padding(.vertical, 4)
                Text("主题会影响侧栏、卡片、按钮和页面背景；深色 / 浅色外观都会自动适配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                LabeledContent("runtime dylib", value: model.bundledRuntimeDylibURL?.path ?? "未构建")
                Text("打包版会把这些文件放在 ExtraWeChat.app/Contents/Resources 下。开发时可用 EXTRAWECHAT_TOOLS_DIR 指向仓库 tools 目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func themeCard(_ theme: AppTheme) -> some View {
        let selected = model.theme == theme
        return Button {
            model.theme = theme
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ThemeSwatch(theme: theme)
                HStack(spacing: 6) {
                    Text(theme.name)
                        .font(.callout.weight(.semibold))
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                    }
                }
                Text(theme.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? theme.accent.opacity(0.13) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? theme.accent.opacity(0.55) : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}
