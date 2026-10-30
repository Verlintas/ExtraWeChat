// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var updateTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AppSection.allCases) { section in
                    sidebarRow(section)
                }
                Spacer(minLength: 12)
                Button {
                    model.openSettings()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .frame(width: 18)
                        Text("设置")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                sidebarFooter
            }
            .padding(12)
            .background {
                ZStack {
                    LinearGradient(
                        colors: colorScheme == .dark ? model.theme.darkBase : model.theme.lightBase,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    model.theme.accent.opacity(colorScheme == .dark ? 0.10 : 0.06)
                }
                .ignoresSafeArea()
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
                .background(ThemeBackground(theme: model.theme))
                .navigationTitle(model.section.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if model.refreshing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            model.openSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("设置")
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新状态")
                        .disabled(model.busy)
                    }
                }
        }
        .environment(\.appTheme, model.theme)
        .tint(model.theme.accent)
        .onReceive(updateTimer) { _ in
            Task { await model.checkForWeChatUpdate() }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                            if model.toast == toast { model.toast = nil }
                        }
                    }
            }
        }
        .overlay {
            if model.busy {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在执行，请稍候…")
                            .font(.callout)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            if model.needsAppManagementHelp {
                Button("打开 App 管理设置") {
                    model.openAppManagementSettings()
                }
            }
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        let selected = model.section == section
        return Button {
            model.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .frame(width: 18)
                Text(section.title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? model.theme.accent.opacity(0.22) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? model.theme.accent.opacity(0.35) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            BrandAssets.appIcon
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("ExtraWeChat \(appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("微信 4.x 实验工具")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        model.theme = theme
                    } label: {
                        Label(theme.name, systemImage: model.theme == theme ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(model.theme.accent)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("切换主题")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .overview:
            OverviewView()
        case .antiRevoke:
            AntiRevokeView()
        case .enhancements:
            EnhancementsView()
        case .instances:
            InstancesView()
        case .loginPersistence:
            LoginPersistenceView()
        case .diagnostics:
            DiagnosticsView()
        case .developer:
            DeveloperView()
        }
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}
