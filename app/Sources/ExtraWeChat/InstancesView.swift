import SwiftUI

struct InstancesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCreate = false
    @State private var deleteTarget: InstanceInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("多开实例")
                        .font(.title2.weight(.semibold))
                    Text("复制 App + 新 bundle ID + 独立数据目录。每个实例需要单独登录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showCreate = true
                } label: {
                    Label("新建实例", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            if model.instances.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text("还没有多开实例")
                        .font(.title3.weight(.semibold))
                    Text("点击右上角“新建实例”创建一个独立微信。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(model.instances) { instance in
                        InstanceRow(instance: instance) {
                            model.launchInstance(instance, loginPersistence: false)
                        } loginLaunch: {
                            model.launchInstance(instance, loginPersistence: true)
                        } delete: {
                            deleteTarget = instance
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showCreate) {
            NewInstanceSheet { name, variant, login in
                Task { await model.createInstance(name: name, variant: variant, loginPersistence: login) }
            }
        }
        .alert("删除实例？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    Task { await model.deleteInstance(target) }
                }
                deleteTarget = nil
            }
        } message: {
            Text("会删除实例 App 和它的独立数据目录。该实例的聊天记录也会被删除，无法恢复。")
        }
    }
}

private struct InstanceRow: View {
    let instance: InstanceInfo
    let launch: () -> Void
    let loginLaunch: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(instance.name)
                        .font(.headline)
                    StatusPill(
                        text: instance.running ? "运行中" : "未运行",
                        color: instance.running ? .green : .secondary
                    )
                    if instance.keyEntries > 0 {
                        StatusPill(text: "key \(instance.keyEntries)", color: .purple)
                    }
                }
                Text(instance.appPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("数据：\(instance.homePath)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("启动", action: launch)
                .buttonStyle(.bordered)
                .disabled(instance.running)
            Button {
                loginLaunch()
            } label: {
                Label("带登录态启动", systemImage: "key.horizontal")
            }
            .buttonStyle(.bordered)
            .disabled(instance.running || !instance.supportsDYLD)
            .help(instance.supportsDYLD ? "使用保存的 key 启动" : "该实例创建时没有启用 allow DYLD 权限")

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除实例")
        }
        .padding(.vertical, 8)
    }
}

private struct NewInstanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var variant = "silent"
    @State private var loginPersistence = false

    let onCreate: (String, String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建多开实例")
                .font(.title2.weight(.semibold))
            Text("实例会复制一份微信 App，使用新的 bundle ID 和独立数据目录。首次启动需要单独登录。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("实例名称", text: $name, prompt: Text("例如：work、小号（建议英文/数字）"))
                Picker("防撤回", selection: $variant) {
                    Text("silent（静默）").tag("silent")
                    Text("keeptip（留提示）").tag("keeptip")
                    Text("不安装").tag("none")
                }
                Toggle("启用登录态保持（实验）", isOn: $loginPersistence)
            }
            .formStyle(.grouped)

            if loginPersistence {
                Text("会为该实例添加 allow-dyld-env 权限，之后可以用保存的 key 启动。需要先在主实例/副本里捕获 key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("创建") {
                    let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !finalName.isEmpty else { return }
                    onCreate(finalName, variant, loginPersistence)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
