// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct EnhancementsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                privacyCard
                roadmapCard
                if !model.log.isEmpty {
                    Card("最近一次操作", icon: "terminal") {
                        LogPanel(text: model.log)
                    }
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    theme.gradient,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("增强")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("不改变聊天协议、只作用于本机补丁副本的小功能。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var privacyCard: some View {
        Card("窗口隐私", icon: "eye.slash.fill") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("录屏 / 共享屏幕时隐藏微信窗口")
                        .font(.headline)
                    Text("包括主窗口、独立聊天窗口、图片查看器和其他面板。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.windowPrivacy },
                    set: { model.windowPrivacy = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if !model.patchedCopyExists {
                WarningBanner(
                    title: "还没有补丁副本",
                    message: "窗口隐私需要注入到补丁副本。请先在「消息防撤回」创建副本。",
                    color: .orange
                )
            } else if !model.windowPrivacySupported {
                WarningBanner(
                    title: "副本缺少 DYLD 权限",
                    message: "请先在「消息防撤回」点「更新副本」，再回来开启窗口隐私。",
                    color: .orange
                )
            } else if model.patchedCopyRunning {
                HStack(spacing: 8) {
                    StatusPill(text: "副本运行中", color: .green)
                    Text(model.windowPrivacy ? "当前设置会在下次启动副本时生效。" : "关闭后需要重启副本恢复截图。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if model.patchedCopyExists {
                    Button {
                        Task { await model.restartPatchedCopy() }
                    } label: {
                        Label("应用并重启副本", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.info?.running == true)
                } else {
                    Button {
                        model.section = .antiRevoke
                    } label: {
                        Label("去创建副本", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }

            Text("限制：这是 macOS 的窗口属性，效果取决于录屏/共享软件；通知横幅和屏幕外的内容不受影响，不能当作安全保证。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var roadmapCard: some View {
        Card("接下来", icon: "sparkles") {
            roadmapRow(
                icon: "text.bubble",
                title: "自定义撤回提示",
                subtitle: "把「对方撤回了一条消息」替换成包含发送者、时间、内容的提示",
                color: .blue
            )
            Divider()
            roadmapRow(
                icon: "clock.arrow.circlepath",
                title: "撤回记录",
                subtitle: "本机记录被拦截的撤回，默认关闭，不上传",
                color: .purple
            )
            Divider()
            roadmapRow(
                icon: "bell.badge",
                title: "关键词提醒",
                subtitle: "静音群里出现关键词时发一条本地通知",
                color: .orange
            )
            Text("这些功能需要按微信构建注入 runtime hook；会先在小范围测试，再放进正式版。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func roadmapRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.callout.weight(.medium))
                    Text("规划中")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.12), in: Capsule())
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
