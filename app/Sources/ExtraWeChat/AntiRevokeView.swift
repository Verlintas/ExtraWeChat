import SwiftUI

struct AntiRevokeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var variant = "silent"
    @State private var allowDYLD = false
    @State private var showInstallConfirm = false
    @State private var showRestoreConfirm = false
    @State private var showTestConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                currentStatus
                installCard
                testCard
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
        .alert("创建测试副本？", isPresented: $showTestConfirm) {
            Button("取消", role: .cancel) {}
            Button("创建") {
                Task { await model.createTestCopy(variant: variant) }
            }
        } message: {
            Text("会在 ~/Applications/ExtraWeChat/Test 创建一个副本，不会修改主微信。副本仍使用原 bundle ID，启动前需要退出微信。")
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
        }
    }

    private var installCard: some View {
        Card("安装 / 还原", icon: "wrench.and.screwdriver") {
            if model.info?.running == true {
                WarningBanner(
                    title: "微信正在运行",
                    message: "安装或还原前需要完全退出微信（⌘Q，并等待 helper 退出）。",
                    color: .red
                )
            }
            Picker("防撤回模式", selection: $variant) {
                Text("silent（保留消息，不显示撤回提示）").tag("silent")
                Text("keeptip（保留消息，私聊保留提示）").tag("keeptip")
            }
            .pickerStyle(.radioGroup)

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

    private var testCard: some View {
        Card("先在副本上测试", icon: "doc.on.doc") {
            Text("创建一个保留原 bundle ID / 沙盒的副本，先验证补丁和签名；确认可用后再安装到主微信。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    showTestConfirm = true
                } label: {
                    Label("创建测试副本", systemImage: "plus.square.on.square")
                }
                .disabled(model.busy)
                Spacer()
            }
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

    private var patchTitle: String {
        switch model.status?.patch_state ?? "pristine" {
        case "silent": return "消息防撤回已开启（静默）"
        case "keeptip": return "消息防撤回已开启（留提示）"
        case "unsupported": return "当前构建不支持"
        default: return "消息防撤回未开启"
        }
    }

    private var patchSubtitle: String {
        if let locate = model.locate {
            return "\(locate.generation ?? "") · newmsgid 字段 0x\(String(locate.field ?? 0, radix: 16))"
        }
        return "未检测到可用补丁点"
    }

    private var patchColor: Color {
        switch model.status?.patch_state ?? "pristine" {
        case "silent", "keeptip": return .green
        case "unsupported": return .red
        default: return .secondary
        }
    }

    private var patchPill: String {
        switch model.status?.patch_state ?? "pristine" {
        case "silent": return "已保护（silent）"
        case "keeptip": return "已保护（keeptip）"
        case "unsupported": return "不支持"
        default: return "未保护"
        }
    }
}
