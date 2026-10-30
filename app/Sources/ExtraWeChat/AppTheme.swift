// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case wechat
    case ocean
    case sunset
    case violet
    case graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .wechat: return "微信绿"
        case .ocean: return "深海蓝"
        case .sunset: return "日落橙"
        case .violet: return "紫罗兰"
        case .graphite: return "石墨灰"
        }
    }

    var subtitle: String {
        switch self {
        case .wechat: return "微信原生绿"
        case .ocean: return "冷静的蓝青"
        case .sunset: return "暖色橙粉"
        case .violet: return "紫色渐变"
        case .graphite: return "低调中性"
        }
    }

    var accent: Color {
        switch self {
        case .wechat: return Color(red: 0.03, green: 0.76, blue: 0.38)
        case .ocean: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .sunset: return Color(red: 0.98, green: 0.45, blue: 0.09)
        case .violet: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .graphite: return Color(red: 0.39, green: 0.45, blue: 0.55)
        }
    }

    var accent2: Color {
        switch self {
        case .wechat: return Color(red: 0.08, green: 0.72, blue: 0.65)
        case .ocean: return Color(red: 0.02, green: 0.71, blue: 0.83)
        case .sunset: return Color(red: 0.93, green: 0.29, blue: 0.60)
        case .violet: return Color(red: 0.39, green: 0.40, blue: 0.95)
        case .graphite: return Color(red: 0.58, green: 0.64, blue: 0.71)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    var darkBase: [Color] {
        switch self {
        case .wechat:
            return [Color(red: 0.02, green: 0.09, blue: 0.06),
                    Color(red: 0.04, green: 0.14, blue: 0.10)]
        case .ocean:
            return [Color(red: 0.02, green: 0.07, blue: 0.14),
                    Color(red: 0.04, green: 0.12, blue: 0.20)]
        case .sunset:
            return [Color(red: 0.12, green: 0.05, blue: 0.04),
                    Color(red: 0.17, green: 0.08, blue: 0.06)]
        case .violet:
            return [Color(red: 0.07, green: 0.05, blue: 0.14),
                    Color(red: 0.11, green: 0.08, blue: 0.20)]
        case .graphite:
            return [Color(red: 0.06, green: 0.07, blue: 0.08),
                    Color(red: 0.09, green: 0.10, blue: 0.12)]
        }
    }

    var lightBase: [Color] {
        switch self {
        case .wechat:
            return [Color(red: 0.95, green: 0.99, blue: 0.97),
                    Color(red: 0.90, green: 0.97, blue: 0.93)]
        case .ocean:
            return [Color(red: 0.96, green: 0.98, blue: 1.00),
                    Color(red: 0.90, green: 0.95, blue: 1.00)]
        case .sunset:
            return [Color(red: 1.00, green: 0.97, blue: 0.95),
                    Color(red: 1.00, green: 0.92, blue: 0.90)]
        case .violet:
            return [Color(red: 0.98, green: 0.96, blue: 1.00),
                    Color(red: 0.94, green: 0.91, blue: 1.00)]
        case .graphite:
            return [Color(red: 0.97, green: 0.97, blue: 0.98),
                    Color(red: 0.93, green: 0.94, blue: 0.95)]
        }
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .wechat
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

struct ThemeBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let theme: AppTheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark ? theme.darkBase : theme.lightBase,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    theme.accent.opacity(colorScheme == .dark ? 0.20 : 0.12),
                    theme.accent2.opacity(colorScheme == .dark ? 0.10 : 0.07),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [theme.accent.opacity(colorScheme == .dark ? 0.16 : 0.10), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 650
            )
        }
        .ignoresSafeArea()
    }
}

struct ThemeSwatch: View {
    let theme: AppTheme

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(theme.gradient)
            .frame(height: 42)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18))
            )
    }
}
