import SwiftUI

struct LoginPersistenceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showEnableConfirm = false
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WarningBanner(
                    title: "实验功能：保存的是登录凭据",
                    message: "本功能会在本机保存微信的 autoauth key，用于在 key 被清空时尝试恢复登录。它可能被服务端拒绝，也可能降低账号安全性。只在你自己的机器和账号上使用；不要上传或分享 key 文件。"
                )

                statusCard
                actionsCard
                captureGuide
                instanceKeys

                if !model.log.isEmpty {
                    Card("最近一次操作", icon: "terminal") {
                        LogPanel(text: model.log)
                    }
                }
            }
            .padding(24)
        }
        .alert("启用主微信登录态保持？", isPresented: $showEnableConfirm) {
            Button("取消", role: .cancel) {}
            Button("启用", role: .destructive) {
                Task { await model.enableLoginPersistenceOnMain(variant: currentVariant) }
            }
        } message: {
            Text("这会给 /Applications/WeChat.app 增加 allow-dyld-env 权限并重新签名，同时保留/安装防撤回补丁。请先退出微信并备份数据。")
        }
        .alert("清除保存的 key？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task { await model.clearLoginKeys() }
            }
        } message: {
            Text("会删除主微信和所有实例的 login_keys.tsv。删除后下次登录需要重新走手机确认。")
        }
    }

    private var statusCard: some View {
        Card("当前状态", icon: "key.horizontal") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.mainSupportsDYLD ? "主微信已允许 DYLD 注入" : "主微信尚未启用")
                        .font(.title3.weight(.semibold))
                    Text(model.mainSupportsDYLD
                         ? "启动时会把登录态 dylib 注入微信；key 为空时会尝试使用保存值。"
                         : "需要先给主微信增加 allow-dyld-env 权限，才能注入登录态 dylib。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    text: model.mainSupportsDYLD ? "已启用" : "未启用",
                    color: model.mainSupportsDYLD ? .green : .orange
                )
            }
            Divider()
            KeyValueRow(key: "主微信 key", value: keySummary(model.loginKeys.main))
            KeyValueRow(key: "实例 key", value: "\(model.loginKeys.instances.count) 个文件")
            KeyValueRow(key: "key 文件", value: model.mainKeyPath.path)
            KeyValueRow(key: "运行日志", value: model.mainLogPath.path)
            KeyValueRow(key: "防撤回状态", value: patchTitle)
        }
    }

    private var actionsCard: some View {
        Card("操作", icon: "play.circle") {
            HStack(spacing: 10) {
                Button {
                    showEnableConfirm = true
                } label: {
                    Label("启用主微信登录态保持", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.info?.running == true)

                Button {
                    model.launchMain(loginPersistence: true)
                } label: {
                    Label("带登录态启动微信", systemImage: "play.fill")
                }
                .disabled(model.busy || model.info?.running == true || !model.mainSupportsDYLD)

                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    model.openLog()
                } label: {
                    Label("打开日志", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    model.openKeyFolder()
                } label: {
                    Label("打开 key 目录", systemImage: "folder")
                }
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清除 key", systemImage: "trash")
                }
                .disabled(!model.loginKeys.hasAny)
                Spacer()
            }
        }
    }

    private var captureGuide: some View {
        Card("怎么用", icon: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "点击“启用主微信登录态保持”，退出微信后确认。")
                step(2, "点击“带登录态启动微信”，按正常流程登录一次。dylib 会捕获 autoauth key。")
                step(3, "下次启动时，如果微信自己读到的 key 为空，dylib 会注入保存值并尝试 autoauth。")
                step(4, "如果微信仍然要求手机确认，说明服务端拒绝了；这属于预期内的失败，不是崩溃。")
                step(5, "随时可以“清除 key”，恢复官方登录流程。")
            }
        }
    }

    private var instanceKeys: some View {
        Card("实例 key", icon: "square.on.square") {
            if model.instances.isEmpty {
                Text("还没有多开实例。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.instances) { instance in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(instance.name).font(.callout.weight(.medium))
                            Text(instance.homePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        StatusPill(
                            text: instance.keyEntries > 0 ? "key \(instance.keyEntries)" : "无 key",
                            color: instance.keyEntries > 0 ? .purple : .secondary
                        )
                        Button("带登录态启动") {
                            model.launchInstance(instance, loginPersistence: true)
                        }
                        .buttonStyle(.bordered)
                        .disabled(instance.running || !instance.supportsDYLD)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.blue))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keySummary(_ key: KeyInfo?) -> String {
        guard let key else { return "未捕获" }
        let date = key.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
        return "\(key.entries) 条 / \(key.bytes) 字节 / \(date)"
    }

    private var currentVariant: String {
        switch model.status?.patch_state {
        case "keeptip": return "keeptip"
        case "silent": return "silent"
        default: return "silent"
        }
    }

    private var patchTitle: String {
        switch model.status?.patch_state ?? "pristine" {
        case "silent": return "已安装（silent）"
        case "keeptip": return "已安装（keeptip）"
        case "unsupported": return "不支持当前构建"
        default: return "未安装"
        }
    }
}
