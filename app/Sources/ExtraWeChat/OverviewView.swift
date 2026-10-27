import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.toolsDir == nil || model.pythonURL == nil {
                    WarningBanner(
                        title: "运行环境不完整",
                        message: "需要 python3 和内置 tools 目录。请使用打包后的 ExtraWeChat.app，或安装 Xcode Command Line Tools（xcode-select --install）。"
                    )
                }
                statusGrid
                quickActions
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
        HStack(alignment: .top, spacing: 18) {
            BrandAssets.appIcon
                .resizable()
                .interpolation(.high)
                .frame(width: 78, height: 78)
                .shadow(color: .blue.opacity(0.25), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("ExtraWeChat")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("为微信 4.x 重新实现的小助手：防撤回、多开、登录态保持。")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let info = model.info {
                        StatusPill(text: info.displayVersion, color: .blue)
                        StatusPill(text: info.channelTitle, color: .purple)
                        StatusPill(text: info.running ? "运行中" : "已退出", color: info.running ? .green : .secondary)
                    } else {
                        StatusPill(text: "未检测到微信", color: .red)
                    }
                }
            }
            Spacer()
        }
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
            Card("消息防撤回", icon: "arrow.uturn.backward.circle") {
                HStack {
                    Text(patchTitle)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    StatusPill(text: patchColorTitle, color: patchColor)
                }
                Text(patchSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.patchedCopyExists {
                    HStack {
                        Text("补丁副本")
                            .font(.callout)
                        Spacer()
                        StatusPill(
                            text: model.patchedCopyRunning ? "运行中" : "已就绪",
                            color: model.patchedCopyRunning ? .green : .blue
                        )
                    }
                }
                Button("打开设置") { model.section = .antiRevoke }
                    .buttonStyle(.link)
            }

            Card("多开实例", icon: "square.on.square") {
                Text("\(model.instances.count)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(model.instances.isEmpty ? "还没有创建独立实例" : "每个实例有独立数据目录，需要单独登录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("管理实例") { model.section = .instances }
                    .buttonStyle(.link)
            }

            Card("登录态保持", icon: "key.horizontal") {
                HStack {
                    Text(model.loginKeys.hasAny ? "已保存 key" : "未捕获")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    StatusPill(
                        text: model.mainSupportsDYLD ? "主微信已允许 DYLD" : "未启用",
                        color: model.mainSupportsDYLD ? .green : .orange
                    )
                }
                Text("实验功能：只应在本机、本人账号使用；服务端仍可能要求手机确认。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("打开设置") { model.section = .loginPersistence }
                    .buttonStyle(.link)
            }

            Card("微信状态", icon: "info.circle") {
                KeyValueRow(key: "路径", value: model.wechatPath)
                KeyValueRow(key: "版本", value: model.info?.displayVersion ?? "—")
                KeyValueRow(key: "渠道", value: model.info?.channelTitle ?? "—")
                KeyValueRow(key: "原微信", value: model.info?.running == true ? "运行中" : "已退出")
                if model.patchedCopyExists {
                    KeyValueRow(
                        key: "补丁副本",
                        value: model.patchedCopyRunning ? "运行中" : "已就绪"
                    )
                }
            }
        }
    }

    private var quickActions: some View {
        Card("快捷操作", icon: "bolt.fill") {
            HStack(spacing: 10) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy)

                Button {
                    Task { await model.quitWeChat() }
                } label: {
                    Label("退出微信", systemImage: "power")
                }
                .disabled(model.info?.running != true)

                Button {
                    model.openLog()
                } label: {
                    Label("打开日志", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    model.openBackupFolder()
                } label: {
                    Label("备份目录", systemImage: "folder")
                }

                Spacer()
            }
        }
    }

    private var patchTitle: String {
        switch model.status?.patch_state ?? "pristine" {
        case "silent": return "已开启（静默）"
        case "keeptip": return "已开启（留提示）"
        case "unsupported": return "不支持当前构建"
        default:
            if let copy = model.patchedCopyPatchState {
                return "补丁副本已开启（\(copy)）"
            }
            return "未开启"
        }
    }

    private var patchSubtitle: String {
        if model.patchedCopyExists && !(model.status?.patch_state == "silent" || model.status?.patch_state == "keeptip") {
            return model.patchedCopyRunning ? "主微信未修改 · 副本运行中" : "主微信未修改 · 副本已就绪"
        }
        if let locate = model.locate {
            return "\(locate.generation ?? "") · silent \(formatHex(locate.silent_va))"
        }
        return "等待检测微信构建"
    }

    private var patchColor: Color {
        switch model.status?.patch_state ?? "pristine" {
        case "silent", "keeptip": return .green
        case "unsupported": return .red
        default: return model.patchedCopyExists ? .green : .secondary
        }
    }

    private var patchColorTitle: String {
        switch model.status?.patch_state ?? "pristine" {
        case "silent", "keeptip": return "已保护"
        case "unsupported": return "不支持"
        default: return model.patchedCopyExists ? "副本已保护" : "未保护"
        }
    }
}
