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

            Text(statusText)

            Divider()

            if model.patchedCopyNeedsUpdate {
                Button {
                    openAntiRevoke()
                } label: {
                    Label("更新补丁副本…", systemImage: "arrow.triangle.2.circlepath")
                }
            } else if model.patchedCopyRunning {
                Button {
                    model.activatePatchedCopy()
                } label: {
                    Label("打开微信副本", systemImage: "arrow.up.forward.app")
                }
                Button {
                    Task { await model.quitPatchedCopy() }
                } label: {
                    Label("退出微信副本", systemImage: "power")
                }
            } else if model.patchedCopyExists {
                Button {
                    model.launchPatchedCopy()
                } label: {
                    Label("启动微信副本", systemImage: "play.fill")
                }
            } else {
                Button {
                    openAntiRevoke()
                } label: {
                    Label("创建补丁副本…", systemImage: "wand.and.stars")
                }
            }

            Button {
                openAntiRevoke()
            } label: {
                Label("消息防撤回设置…", systemImage: "shield.lefthalf.filled")
            }

            Divider()

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

            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .disabled(model.busy)

            Button("退出 ExtraWeChat") {
                NSApp.terminate(nil)
            }
        }
    }

    private var statusText: String {
        let mode = model.patchedCopyModeLabel.map { " · \($0)" } ?? ""
        if model.patchedCopyNeedsUpdate {
            return "补丁副本：需要更新"
        }
        if model.patchedCopyRunning {
            return "补丁副本：运行中\(mode)"
        }
        if model.patchedCopyExists {
            return "补丁副本：已就绪\(mode)"
        }
        return "补丁副本：未创建"
    }

    private func openAntiRevoke() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        model.section = .antiRevoke
    }
}
