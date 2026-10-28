import SwiftUI

struct AntiRevokeView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("antiRevokeVariant") private var variant = "keeptip"
    @State private var allowDYLD = false
    @State private var showInstallConfirm = false
    @State private var showRestoreConfirm = false
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if model.patchedCopyNeedsUpdate {
                    updateBanner
                }
                if model.info?.running == true {
                    WarningBanner(
                        title: "原微信正在运行",
                        message: "补丁副本和原微信共用数据容器，不能同时运行。请先完全退出原微信（⌘Q，等待 helper 退出）。",
                        color: .red
                    )
                }
                modeCard
                copyCard
                advancedCard
                notice
                if !model.log.isEmpty {
                    Card("最近一次操作", icon: "terminal") {
                        LogPanel(text: model.log)
                    }
                }
            }
            .padding(24)
        }
        .animation(.easeInOut(duration: 0.18), value: model.patchedCopyRunning)
        .animation(.easeInOut(duration: 0.18), value: model.patchedCopyNeedsUpdate)
        .alert("安装到主微信？", isPresented: $showInstallConfirm) {
            Button("取消", role: .cancel) {}
            Button("安装", role: .destructive) {
                Task { await model.installAntiRevoke(variant: variant, allowDYLD: allowDYLD) }
            }
        } message: {
            Text("这会修改 /Applications/WeChat.app 内的 wechat.dylib 并重新签名。macOS 的 App 管理权限可能拦截；失败会自动回滚。请确认微信已完全退出。")
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

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: heroColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 66, height: 66)
                Image(systemName: heroIcon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: heroColors[0].opacity(0.28), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 6) {
                Text(heroTitle)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(heroSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let mode = model.patchedCopyModeLabel {
                        StatusPill(text: "\(mode)模式", color: .green)
                    }
                    StatusPill(
                        text: model.patchedCopyRunning ? "副本运行中" : model.patchedCopyExists ? "副本已就绪" : "未启用",
                        color: copyColor
                    )
                    if model.patchedCopyExists && !isPatched {
                        StatusPill(text: "主微信未修改", color: .secondary)
                    }
                }
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 6) {
                Button(action: primaryAction) {
                    Label(primaryLabel, systemImage: primaryIcon)
                        .frame(minWidth: 118)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(primaryDisabled)

                Text(primaryHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color.teal.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18))
        )
    }

    private var updateBanner: some View {
        WarningBanner(
            title: "微信已更新，副本需要重建",
            message: "主微信是 \(model.info?.displayVersion ?? "新版本")，副本还是 \(model.patchedCopyVersion ?? "旧版本")。点右上角「更新并启动」重建，聊天记录不会丢失。",
            color: .orange
        )
    }

    // MARK: - Mode

    private var modeCard: some View {
        Card("选择防撤回模式", icon: "slider.horizontal.3") {
            HStack(spacing: 12) {
                modeOption(
                    id: "silent",
                    title: "静默模式",
                    subtitle: "消息保留，不显示撤回提示",
                    icon: "bell.slash.fill"
                )
                modeOption(
                    id: "keeptip",
                    title: "提示模式",
                    subtitle: "消息保留，私聊仍显示撤回提示",
                    icon: "bell.fill"
                )
            }
            Text("选择后，创建或更新补丁副本时生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func modeOption(id: String, title: String, subtitle: String, icon: String) -> some View {
        let selected = variant == id
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { variant = id }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Copy management

    private var copyCard: some View {
        Card("补丁副本", icon: "doc.on.doc.fill") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(copyHeadline)
                        .font(.headline)
                    Text("复制到 ~/Applications，使用同一账号和聊天数据；不修改系统微信。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: copyPill, color: copyColor)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await model.createPatchedCopy(variant: variant) }
                } label: {
                    Label(model.patchedCopyExists ? "更新副本" : "创建副本",
                          systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .disabled(model.busy || model.info?.running == true || model.patchedCopyRunning)

                Button {
                    if model.patchedCopyRunning {
                        model.activatePatchedCopy()
                    } else {
                        model.launchPatchedCopy()
                    }
                } label: {
                    Label(model.patchedCopyRunning ? "打开副本" : "启动副本",
                          systemImage: model.patchedCopyRunning ? "arrow.up.forward.app" : "play.fill")
                }
                .disabled(!model.patchedCopyExists || model.info?.running == true)

                Button("退出副本") {
                    Task { await model.quitPatchedCopy() }
                }
                .disabled(!model.patchedCopyRunning)

                Button {
                    model.revealPatchedCopy()
                } label: {
                    Label("Finder", systemImage: "folder")
                }

                Spacer()
            }

            if model.patchedCopyExists {
                Divider()
                KeyValueRow(key: "位置", value: model.patchedCopyPath.path)
                KeyValueRow(key: "版本", value: model.patchedCopyVersion ?? "—")
                if model.patchedCopyNeedsUpdate {
                    KeyValueRow(
                        key: "状态",
                        value: "主微信已更新，需要重建副本"
                    )
                }
            }

            Text("副本和原微信不能同时运行。App Store 更新不会更新副本；微信更新后请点「更新副本」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Advanced main-app install

    private var advancedCard: some View {
        Card("高级", icon: "wrench.and.screwdriver") {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("直接修改 /Applications/WeChat.app。macOS 的「App 管理」TCC 可能拦截，即使管理员授权也不保证成功；失败会自动回滚。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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
                        .buttonStyle(.bordered)
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
                .padding(.top, 8)
            } label: {
                Label("直接修改主微信", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private var notice: some View {
        WarningBanner(
            title: "使用须知",
            message: "修改微信违反腾讯用户协议，存在账号风险。补丁副本与原微信不能同时运行；微信更新后需要重建副本。不要分发打补丁后的微信 App。",
            color: .orange
        )
    }

    // MARK: - Actions

    private func primaryAction() {
        if model.patchedCopyRunning {
            model.activatePatchedCopy()
        } else if model.patchedCopyNeedsUpdate || !model.patchedCopyExists {
            Task { await model.createPatchedCopy(variant: variant) }
        } else {
            model.launchPatchedCopy()
        }
    }

    private var primaryLabel: String {
        if model.patchedCopyRunning { return "打开微信副本" }
        if model.patchedCopyNeedsUpdate { return "更新并启动" }
        if !model.patchedCopyExists { return "创建防撤回副本" }
        return "启动微信副本"
    }

    private var primaryIcon: String {
        if model.patchedCopyRunning { return "arrow.up.forward.app" }
        if model.patchedCopyNeedsUpdate { return "arrow.triangle.2.circlepath" }
        if !model.patchedCopyExists { return "wand.and.stars" }
        return "play.fill"
    }

    private var primaryDisabled: Bool {
        if model.busy { return true }
        if model.patchedCopyRunning { return false }
        return model.info?.running == true
    }

    private var primaryHint: String {
        if model.patchedCopyRunning {
            return model.patchedCopyNeedsUpdate ? "先退出副本再更新" : "副本正在运行"
        }
        if model.info?.running == true {
            return "先退出原微信"
        }
        if model.patchedCopyNeedsUpdate {
            return "聊天记录不会丢失"
        }
        return "不需要管理员权限"
    }

    // MARK: - Status helpers

    private var isPatched: Bool {
        model.status?.patch_state == "silent" || model.status?.patch_state == "keeptip"
    }

    private var heroTitle: String {
        if model.patchedCopyNeedsUpdate { return "副本需要更新" }
        if model.patchedCopyRunning { return "防撤回正在保护" }
        if model.patchedCopyExists { return "防撤回已就绪" }
        return "开启消息防撤回"
    }

    private var heroSubtitle: String {
        if model.patchedCopyNeedsUpdate {
            return "微信已更新，副本还是旧版本。重建后继续使用，聊天记录不会丢失。"
        }
        if model.patchedCopyRunning {
            let mode = model.patchedCopyModeLabel ?? "防撤回"
            return "\(mode)模式正在运行 · 主微信未被修改，副本和原微信共用账号数据。"
        }
        if model.patchedCopyExists {
            return "副本位于 ~/Applications/WeChatExtra.app，启动后使用同一账号和聊天记录。"
        }
        return "推荐用补丁副本：不修改 /Applications，不需要 root 或 App 管理权限。"
    }

    private var heroIcon: String {
        if model.patchedCopyNeedsUpdate { return "arrow.triangle.2.circlepath" }
        if model.patchedCopyRunning { return "checkmark.shield.fill" }
        if model.patchedCopyExists { return "shield.lefthalf.filled" }
        return "shield"
    }

    private var heroColors: [Color] {
        if model.patchedCopyRunning {
            return [.green, .teal]
        }
        if model.patchedCopyExists {
            return [.blue, .teal]
        }
        return [.indigo, .blue]
    }

    private var copyHeadline: String {
        let mode = model.patchedCopyModeLabel.map { " · \($0)" } ?? ""
        if model.patchedCopyRunning { return "微信副本正在运行\(mode)" }
        if model.patchedCopyExists { return "微信副本已就绪\(mode)" }
        return "还没有补丁副本"
    }

    private var copyPill: String {
        if model.patchedCopyNeedsUpdate { return "需要更新" }
        if model.patchedCopyRunning { return "运行中" }
        if model.patchedCopyExists { return "已就绪" }
        return "未创建"
    }

    private var copyColor: Color {
        if model.patchedCopyNeedsUpdate { return .orange }
        if model.patchedCopyRunning { return .green }
        if model.patchedCopyExists { return .blue }
        return .secondary
    }
}
