// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct DeveloperView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showJSON = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                environmentCard
                scanCard
                checksCard
                reportCard
                actionsCard
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(colors: [.orange, .red],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("开发者")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("只读诊断信息，用于排查兼容性。这里不会显示聊天内容或登录 key 原文。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var environmentCard: some View {
        Card("运行环境", icon: "gearshape.2") {
            KeyValueRow(key: "ExtraWeChat", value: appVersion)
            KeyValueRow(key: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            KeyValueRow(key: "CPU", value: ProcessInfo.processInfo.machineHardwareName)
            KeyValueRow(key: "微信路径", value: model.wechatPath)
            KeyValueRow(key: "Python", value: model.pythonURL?.path ?? "未找到")
            KeyValueRow(key: "tools", value: model.toolsDir?.path ?? "未找到")
            KeyValueRow(key: "runtime dylib", value: model.bundledRuntimeDylibURL?.path ?? "未找到")
            KeyValueRow(key: "profiles", value: model.profilesPath?.path ?? "未找到")
            KeyValueRow(key: "数据目录", value: model.dataDir.path)
        }
    }

    private var scanCard: some View {
        Card("微信扫描", icon: "waveform.path.ecg") {
            KeyValueRow(key: "版本", value: model.info?.displayVersion ?? "—")
            KeyValueRow(key: "构建号", value: model.info?.build ?? "—")
            KeyValueRow(key: "渠道", value: model.info?.channelTitle ?? "—")
            KeyValueRow(key: "匹配方式", value: matchLabel)
            KeyValueRow(key: "目标架构", value: model.locate?.arch ?? "—")
            KeyValueRow(key: "签名代", value: model.locate?.generation ?? "—")
            KeyValueRow(key: "silent", value: stateLabel(model.locate?.silent_state))
            KeyValueRow(key: "keeptip", value: stateLabel(model.locate?.keeptip_state))
            KeyValueRow(key: "silent 地址", value: formatHex(model.locate?.silent_va))
            KeyValueRow(key: "keeptip 地址", value: formatHex(model.locate?.keeptip_va))
            KeyValueRow(key: "newmsgid", value: model.locate?.field.map { "0x" + String($0, radix: 16) } ?? "—")
            KeyValueRow(key: "delta", value: model.locate?.delta.map { "0x" + String($0, radix: 16) } ?? "—")
            Divider()
            KeyValueRow(key: "副本", value: model.patchedCopyExists ? (model.patchedCopyVersion ?? "已创建") : "未创建")
            KeyValueRow(key: "副本构建号", value: model.patchedCopyBuild ?? "—")
            KeyValueRow(key: "副本 DYLD", value: model.patchedCopySupportsDYLD ? "允许" : "未允许")
            KeyValueRow(key: "副本需要重建", value: model.patchedCopyNeedsUpdate ? "是" : "否")
        }
    }

    private var checksCard: some View {
        Card("兼容性检查", icon: "checklist") {
            checkRow("当前构建匹配", ok: model.locate != nil, detail: matchLabel)
            checkRow("silent 补丁点可用", ok: model.locate?.silent_state != nil, detail: stateLabel(model.locate?.silent_state))
            checkRow("keeptip 补丁点可用", ok: model.locate?.keeptip_state != nil, detail: stateLabel(model.locate?.keeptip_state))
            checkRow("内置构建表", ok: (model.profileSummary()?.builds ?? 0) > 0,
                     detail: "\(model.profileSummary()?.builds ?? 0) 个构建 / \(model.profileSummary()?.generations ?? 0) 代签名")
            checkRow("补丁副本", ok: model.patchedCopyExists, detail: model.patchedCopyExists ? "已创建" : "未创建")
            checkRow("副本 DYLD", ok: model.patchedCopySupportsDYLD, detail: model.patchedCopySupportsDYLD ? "允许" : "未允许")
            checkRow("runtime dylib", ok: model.bundledRuntimeDylibURL != nil,
                     detail: model.bundledRuntimeDylibURL == nil ? "缺失" : "存在")
            checkRow("副本版本一致", ok: !model.patchedCopyNeedsUpdate,
                     detail: model.patchedCopyNeedsUpdate ? "需要重建" : "一致")

            HStack(spacing: 10) {
                Button {
                    Task { await model.verifySignatures() }
                } label: {
                    Label("验证签名", systemImage: "checkmark.seal")
                }
                .disabled(model.verifyingSignatures)
                if model.verifyingSignatures {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if let report = model.signatureReport {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reportCard: some View {
        Card("诊断报告", icon: "doc.text.magnifyingglass") {
            Text("复制或导出当前环境、匹配结果和原始 JSON。报告不包含聊天内容或 key 原文。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    model.copyDeveloperReport()
                } label: {
                    Label("复制报告", systemImage: "doc.on.doc")
                }
                Button {
                    model.exportDeveloperReport()
                } label: {
                    Label("导出…", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            DisclosureGroup("查看原始 JSON", isExpanded: $showJSON) {
                VStack(alignment: .leading, spacing: 10) {
                    jsonBlock("locate_revoke --json", model.locateJSON)
                    jsonBlock("install.py status --json", model.statusJSON)
                    jsonBlock("副本 status --json", model.copyStatusJSON)
                }
                .padding(.top, 8)
            }
        }
    }

    private var actionsCard: some View {
        Card("工具", icon: "wrench.and.screwdriver") {
            HStack(spacing: 10) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy)
                Button {
                    model.openProfilesFile()
                } label: {
                    Label("打开 profiles", systemImage: "doc.text")
                }
                Button {
                    model.openToolsFolder()
                } label: {
                    Label("打开 tools", systemImage: "folder")
                }
                Button {
                    model.openLog()
                } label: {
                    Label("打开日志", systemImage: "terminal")
                }
                Spacer()
            }
        }
    }

    private func checkRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title)
                .font(.callout)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func jsonBlock(_ title: String, _ json: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(json ?? "(未获取)")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var matchLabel: String {
        switch model.locate?.match {
        case "profile": return "内置构建配置"
        case "signature": return "arm64 几何签名"
        default: return "未匹配"
        }
    }

    private func stateLabel(_ state: String?) -> String {
        switch state {
        case "pristine": return "原始 / 可打补丁"
        case "patched-silent": return "已打 silent"
        case "patched-keeptip": return "已打 keeptip"
        case "unsupported": return "不支持"
        default: return "—"
        }
    }
}
