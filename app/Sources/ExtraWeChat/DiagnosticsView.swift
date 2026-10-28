import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("诊断")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.busy)
                    Button {
                        model.copyDiagnostics()
                    } label: {
                        Label("复制诊断", systemImage: "doc.on.doc")
                    }
                }

                Card("环境", icon: "gear") {
                    KeyValueRow(key: "微信路径", value: model.wechatPath)
                    KeyValueRow(key: "微信版本", value: model.info?.displayVersion ?? "—")
                    KeyValueRow(key: "Python", value: model.pythonURL?.path ?? "未找到")
                    KeyValueRow(key: "tools", value: model.toolsDir?.path ?? "未找到")
                    KeyValueRow(key: "login dylib", value: model.bundledDylibURL?.path ?? "未构建/未打包")
                    KeyValueRow(key: "数据目录", value: model.dataDir.path)
                    KeyValueRow(key: "备份目录", value: model.backupDir.path)
                }

                Card("补丁状态", icon: "shield.lefthalf.filled") {
                    KeyValueRow(key: "patch", value: model.status?.patch_state ?? "—")
                    KeyValueRow(key: "generation", value: model.locate?.generation ?? "—")
                    KeyValueRow(key: "silent VA", value: formatHex(model.locate?.silent_va))
                    KeyValueRow(key: "keeptip VA", value: formatHex(model.locate?.keeptip_va))
                    KeyValueRow(key: "silent 当前", value: model.locate?.silent_current ?? "—")
                    KeyValueRow(key: "keeptip 当前", value: model.locate?.keeptip_current ?? "—")
                    KeyValueRow(key: "备份", value: model.status?.has_backup == true ? "有" : "无")
                    KeyValueRow(key: "主微信 DYLD", value: model.mainSupportsDYLD ? "已允许" : "未允许")
                }

                Card("补丁副本", icon: "doc.on.doc") {
                    if model.patchedCopyExists {
                        KeyValueRow(key: "状态", value: model.patchedCopyRunning ? "运行中" : "已就绪")
                        KeyValueRow(key: "模式", value: model.patchedCopyModeLabel ?? "—")
                        KeyValueRow(key: "路径", value: model.patchedCopyPath.path)
                        KeyValueRow(key: "版本", value: model.patchedCopyVersion ?? "—")
                        KeyValueRow(key: "主微信版本", value: model.info?.displayVersion ?? "—")
                        KeyValueRow(key: "需要重建", value: model.patchedCopyNeedsUpdate ? "是" : "否")
                    } else {
                        Text("未创建").foregroundStyle(.secondary)
                    }
                }

                Card("实例", icon: "square.on.square") {
                    if model.instances.isEmpty {
                        Text("无").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.instances) { instance in
                            KeyValueRow(
                                key: instance.name,
                                value: "\(instance.appPath) · key \(instance.keyEntries)"
                            )
                        }
                    }
                }

                if !model.log.isEmpty {
                    Card("命令输出", icon: "terminal") {
                        LogPanel(text: model.log)
                    }
                }

                Text("注意：这里的输出不包含 autoauth key 原文；key 只保存在 login_keys.tsv（0600）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}
