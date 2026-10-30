// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

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
            CommandMenu("视图") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) {
                        model.section = section
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                }
            }

            CommandMenu("微信") {
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
                .frame(width: 640, height: 560)
        }
    }
}
