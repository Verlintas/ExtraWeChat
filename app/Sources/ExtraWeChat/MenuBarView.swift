import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("打开 ExtraWeChat", systemImage: "macwindow")
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .disabled(model.busy)

            Divider()

            if let patch = model.status?.patch_state, patch == "silent" || patch == "keeptip" {
                Button {
                    Task { await model.restoreAntiRevoke() }
                } label: {
                    Label("还原消息防撤回", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.busy || model.info?.running == true)
            } else {
                Button {
                    Task { await model.installAntiRevoke(variant: "silent", allowDYLD: false) }
                } label: {
                    Label("开启消息防撤回（silent）", systemImage: "checkmark.shield")
                }
                .disabled(model.busy || model.info?.running == true)
            }

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.section = .loginPersistence
            } label: {
                Label("登录态保持设置…", systemImage: "key.horizontal")
            }

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.section = .instances
            } label: {
                Label("多开实例…", systemImage: "square.on.square")
            }

            Divider()

            Button("退出 ExtraWeChat") {
                NSApp.terminate(nil)
            }
        }
    }
}
