import SwiftUI

struct AntiRevokeView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("antiRevokeVariant") private var variant = "keeptip"
    @State private var allowDYLD = false
    @State private var showInstallConfirm = false
    @State private var showRestoreConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                currentStatus
                modeCard
                patchedCopyCard
                installCard
                warning
                if !model.log.isEmpty {
                    Card("最近一次操作", icon: "terminal") {
                        LogPanel(text: model.log)
                    }
                }
            }
            .padding(24)
        }
        .alert("安装到主微信？", isPresented: $showInstallConfirm) {
            Button("取消", role: .cancel) {}
            Button("安装", role: .destructive) {
                Task { await model.installAntiRevoke(variant: variant, allowDYLD: allowDYLD) }
            }
        } message: {
            Text("这会修改 /Applications/WeChat.app 内的 wechat.dylib 并重新签名。请确认微信已完全退出，并已备份重要聊天数据。支持一键还原。")
        }
        .alert("还原微信？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("还原", role: .destructive) {
                Task { await model.restoreAntiRevoke() }
            }
        } message: {
            Text("将用备份的原始 wechat.dylib 覆盖并重新签名。微信会恢复到未修改状态。")
        }
    }

    private var currentStatus: some View {
        Card("当前状态", icon: "shield.lefthalf.filled") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(patchTitle)
                        .font(.title2.weight(.semibold))
                    Text(patchSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: patchPill, color: patchColor)
            }
            Divider()
            KeyValueRow(key: "微信版本", value: model.info?.displayVersion ?? "—")
            KeyValueRow(key: "构建号", value: model.info?.build ?? "—")
            KeyValueRow(key: "渠道", value: model.info?.channelTitle ?? "—")
            KeyValueRow(key: "补丁代", value: model.locate?.generation ?? "—")
            KeyValueRow(key: "silent 地址", value: formatHex(model.locate?.silent_va))
            KeyValueRow(key: "keeptip 地址", value: formatHex(model.locate?.keeptip_va))
            KeyValueRow(key: "备份", value: model.status?.has_backup == true ? (model.status?.backup_dir ?? "有") : "无")
            if model.patchedCopyExists {
                KeyValueRow(
                    key: "补丁副本",
                    value: "\(model.patchedCopyPatchState ?? "已创建") · \(model.patchedCopyRunning ? "运行中" : "未运行")"
                )
            }
        }
    }

    private var modeCard: some View {
        Card("防撤回模式", icon: "slider.horizontal.3") {
            Picker("防撤回模式", selection: $variant) {
                Text("silent（保留消息，不显示撤回提示）").tag("silent")
                Text("keeptip（保留消息，私聊保留提示）").tag("keeptip")
            }
            .pickerStyle(.radioGroup)
            Text("推荐先用补丁副本验证；确认有效后再决定是否修改主微信。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var patchedCopyCard: some View {
        Card("补丁副本（推荐，无需 App 管理权限）", icon: "doc.on.doc.fill") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copyTitle)
                        .font(.title3.weight(.semibold))
                    Text("复制一份微信到 ~/Applications，打补丁并重签；不修改 /Applications/WeChat.app。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: copyPill, color: copyColor)
            }
            if model.info?.running == true {
                WarningBanner(
                    title: "原微信正在运行",
                    message: "补丁副本和原微信共用数据容器，不能同时运行。请先完全退出原微信。",
                    color: .red
                )
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.createPatchedCopy(variant: variant) }
                } label: {
                    Label(model.patchedCopyExists ? "更新并启动" : "创建并启动",
                          systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.info?.running == true || model.patchedCopyRunning)

                Button("启动副本") {
                    model.launchPatchedCopy()
                }
                .disabled(!model.patchedCopyExists || model.patchedCopyRunning || model.info?.running == true)

                Button("退出副本") {
                    Task { await model.quitPatchedCopy() }
                }
                .disabled(!model.patchedCopyRunning)

                Button("在 Finder 显示") {
                    model.revealPatchedCopy()
                }

                Spacer()
            }
            if model.patchedCopyExists {
                KeyValueRow(key: "位置", value: model.patchedCopyPath.path)
                KeyValueRow(key: "版本", value: model.patchedCopyVersion ?? "—")
            }
            Text("副本使用相同的 bundle ID 和沙盒容器，所以账号和聊天记录是同一份。App Store 更新不会更新副本；微信更新后需要重新创建。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var installCard: some View {
        Card("修改主微信（需要 App 管理 + 管理员密码）", icon: "wrench.and.screwdriver") {
            if model.info?.running == true {
                WarningBanner(
                    title: "微信正在运行",
                    message: "安装或还原前需要完全退出微信（⌘Q，并等待 helper 退出）。",
                    color: .red
                )
            }
            Toggle("同时启用登录态保持（allow DYLD）", isOn: $allowDYLD)
                .toggleStyle(.switch)
            Text("开启后，主微信会允许通过 DYLD 注入登录态 dylib。该权限会降低进程安全性，只建议在你自己的机器上使用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    showInstallConfirm = true
                } label: {
                    Label("安装到主微信", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.info?.running == true)

                Button {
                    showRestoreConfirm = true
                } label: {
                    Label("还原微信", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.busy || model.info?.running == true || !isPatched)

                Spacer()
            }
            Button("打开 App 管理设置") {
                model.openAppManagementSettings()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private var warning: some View {
        WarningBanner(
            title: "风险提示",
            message: "修改微信违反腾讯用户协议，存在账号风险；微信更新会整包替换并清除补丁。安装前请备份聊天数据和原始 wechat.dylib，不要分发打补丁后的微信 App。"
        )
    }

    private var isPatched: Bool {
        model.status?.patch_state == "silent" || model.status?.patch_state == "keeptip"
    }

    private var copyTitle: String {
        let mode = model.patchedCopyPatchState.map { "（\($0)）" } ?? ""
        if model.patchedCopyRunning { return "补丁副本正在运行\(mode)" }
        if model.patchedCopyExists { return "补丁副本已就绪\(mode)" }
        return "还没有补丁副本"
    }

    private var copyPill: String {
        if model.patchedCopyRunning { return "运行中" }
        if model.patchedCopyExists { return "已创建" }
        return "未创建"
    }

    private var copyColor: Color {
        if model.patchedCopyRunning { return .green }
        if model.patchedCopyExists { return .blue }
        return .secondary
    }

    private var patchTitle: String {
        switch model.status?.patch_state ?? "pristine" {
        case "silent": return "主微信已开启（静默）"
        case "keeptip": return "主微信已开启（留提示）"
        case "unsupported": return "当前构建不支持"
        default:
            if let copy = model.patchedCopyPatchState {
                return "补丁副本已开启（\(copy)）"
            }
            return "消息防撤回未开启"
        }
    }

    private var patchSubtitle: String {
        if let locate = model.locate {
            let suffix = model.patchedCopyExists && !isPatched ? " · 主微信未修改" : ""
            return "\(locate.generation ?? "") · newmsgid 字段 0x\(String(locate.field ?? 0, radix: 16))\(suffix)"
        }
        return "未检测到可用补丁点"
    }

    private var patchColor: Color {
        switch model.status?.patch_state ?? "pristine" {
        case "silent", "keeptip": return .green
        case "unsupported": return .red
        default: return model.patchedCopyExists ? .green : .secondary
        }
    }

    private var patchPill: String {
        switch model.status?.patch_state ?? "pristine" {
        case "silent": return "主微信已保护（silent）"
        case "keeptip": return "主微信已保护（keeptip）"
        case "unsupported": return "不支持"
        default:
            return model.patchedCopyExists ? "副本已保护" : "未保护"
        }
    }
}
