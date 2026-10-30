// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case antiRevoke
    case enhancements
    case instances
    case loginPersistence
    case diagnostics
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .antiRevoke: return "消息防撤回"
        case .enhancements: return "增强"
        case .instances: return "多开实例"
        case .loginPersistence: return "登录态保持"
        case .diagnostics: return "诊断"
        case .developer: return "开发者"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .antiRevoke: return "arrow.uturn.backward.circle"
        case .enhancements: return "wand.and.stars"
        case .instances: return "square.on.square"
        case .loginPersistence: return "key.horizontal"
        case .diagnostics: return "stethoscope"
        case .developer: return "hammer.fill"
        }
    }
}

struct WeChatInfo: Equatable {
    var path: String
    var bundleID: String
    var shortVersion: String
    var build: String
    var fullVersion: String?
    var channel: String
    var running: Bool

    var displayVersion: String {
        if let fullVersion, !fullVersion.isEmpty {
            return "\(shortVersion) (\(build)) · \(fullVersion)"
        }
        return "\(shortVersion) (\(build))"
    }

    var channelTitle: String {
        channel == "appStore" ? "App Store" : "官网版"
    }
}

struct LocateInfo: Decodable, Equatable {
    var generation: String?
    var match: String?
    var arch: String?
    var profiles_path: String?
    var profiles_source: String?
    var entry_va: UInt64?
    var silent_va: UInt64?
    var keeptip_va: UInt64?
    var silent_current: String?
    var silent_pristine: String?
    var silent_patch: String?
    var silent_state: String?
    var keeptip_current: String?
    var keeptip_pristine: String?
    var keeptip_patch: String?
    var keeptip_state: String?
    var field: UInt64?
    var delta: UInt64?
    var prologue_ok: Bool?
    var bundle_id: String?
    var short_version: String?
    var build: String?
    var channel: String?
    var error: String?
}

struct InstallStatus: Decodable, Equatable {
    var app: String?
    var bundle_id: String?
    var short_version: String?
    var build: String?
    var channel: String?
    var backup_dir: String?
    var has_backup: Bool?
    var running: Bool?
    var generation: String?
    var match: String?
    var arch: String?
    var silent_state: String?
    var keeptip_state: String?
    var patch_state: String?
    var error: String?
}

struct InstanceInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var appPath: String
    var homePath: String
    var bundleID: String
    var running: Bool
    var supportsDYLD: Bool
    var keyBytes: Int
    var keyEntries: Int
}

struct KeyInfo: Equatable {
    var path: String
    var bytes: Int
    var entries: Int
    var modified: Date?
}

struct LoginKeySummary: Equatable {
    var main: KeyInfo?
    var instances: [KeyInfo]

    var hasAny: Bool {
        main != nil || !instances.isEmpty
    }
}

enum ToolError: LocalizedError {
    case missingPython
    case missingTool(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingPython:
            return "找不到 python3。请安装 Xcode Command Line Tools（xcode-select --install）或 Python 3。"
        case .missingTool(let name):
            return "找不到内置工具：\(name)。请使用打包后的 ExtraWeChat.app，或设置 EXTRAWECHAT_TOOLS_DIR。"
        case .failed(let message):
            return message
        }
    }
}

func formatHex(_ value: UInt64?) -> String {
    guard let value else { return "—" }
    return "0x" + String(value, radix: 16)
}

extension ProcessInfo {
    var machineHardwareName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
