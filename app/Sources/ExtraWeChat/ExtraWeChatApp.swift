import AppKit
import SwiftUI

@main
struct ExtraWeChatApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ExtraWeChat", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
                .task { await model.refresh() }
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("ExtraWeChat") {
                Button("刷新状态") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("退出微信") {
                    Task { await model.quitWeChat() }
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(nsImage: BrandAssets.menuBarIcon)
                .accessibilityLabel("ExtraWeChat")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560, height: 320)
        }
    }
}
