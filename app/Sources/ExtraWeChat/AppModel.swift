// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .overview
    @Published var wechatPath: String = "/Applications/WeChat.app"
    @Published var info: WeChatInfo?
    @Published var locate: LocateInfo?
    @Published var status: InstallStatus?
    @Published var instances: [InstanceInfo] = []
    @Published var loginKeys = LoginKeySummary(main: nil, instances: [])
    @Published var mainSupportsDYLD = false
    @Published var patchedCopyExists = false
    @Published var patchedCopyRunning = false
    @Published var patchedCopyVersion: String?
    @Published var patchedCopyBuild: String?
    @Published var patchedCopyPatchState: String?
    @Published var patchedCopySupportsDYLD = false
    @Published var windowPrivacy: Bool {
        didSet { UserDefaults.standard.set(windowPrivacy, forKey: "windowPrivacy") }
    }
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") }
    }
    @Published var busy = false
    @Published var refreshing = false
    @Published var log = ""
    @Published var locateJSON: String?
    @Published var statusJSON: String?
    @Published var copyStatusJSON: String?
    @Published var signatureReport: String?
    @Published var verifyingSignatures = false
    @Published var errorMessage: String?
    @Published var toast: String?

    var needsAppManagementHelp: Bool {
        guard let errorMessage else { return false }
        return errorMessage.contains("App 管理")
            || errorMessage.contains("Operation not permitted")
            || errorMessage.contains("Permission denied")
    }

    let dataDir: URL
    let instancesDir: URL
    let backupDir: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        dataDir = support.appendingPathComponent("ExtraWeChat", isDirectory: true)
        instancesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/ExtraWeChat/Instances", isDirectory: true)
        backupDir = dataDir.appendingPathComponent("backups", isDirectory: true)
        windowPrivacy = UserDefaults.standard.bool(forKey: "windowPrivacy")
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .wechat
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: instancesDir, withIntermediateDirectories: true)
    }

    // MARK: - Paths / tools

    var toolsDir: URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["EXTRAWECHAT_TOOLS_DIR"] {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("tools", isDirectory: true),
           fm.fileExists(atPath: res.path) {
            return res
        }
        // Development fallback: cwd/tools, cwd/../tools, executable/../../tools.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("tools", isDirectory: true),
            cwd.appendingPathComponent("../tools", isDirectory: true),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("tools", isDirectory: true),
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
        return nil
    }

    var pythonURL: URL? {
        let fm = FileManager.default
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let p = String(dir) + "/python3"
                if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
            }
        }
        return nil
    }

    var bundledDylibURL: URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("libExtraWeChatLogin.dylib"),
           fm.fileExists(atPath: res.path) {
            return res
        }
        if let tools = toolsDir {
            let candidates = [
                tools.appendingPathComponent("login_persist/build/libExtraWeChatLogin.dylib"),
                tools.appendingPathComponent("../tools/login_persist/build/libExtraWeChatLogin.dylib"),
            ]
            for c in candidates where fm.fileExists(atPath: c.path) {
                return c.standardizedFileURL
            }
        }
        return nil
    }

    var patchedCopyPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/WeChatExtra.app", isDirectory: true)
    }

    var patchedCopyMarker: URL {
        dataDir.appendingPathComponent("patched-copy.json")
    }

    var profilesPath: URL? {
        toolsDir?.appendingPathComponent("revoke_profiles.json")
    }

    func profileSummary() -> (builds: Int, generations: Int)? {
        guard let url = profilesPath,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let builds = (object["builds"] as? [String: Any])?.count ?? 0
        let generations = (object["generations"] as? [Any])?.count ?? 0
        return (builds, generations)
    }

    var patchedCopyNeedsUpdate: Bool {
        guard patchedCopyExists,
              let current = info?.build,
              let copyBuild = patchedCopyBuild
        else { return false }
        return current != copyBuild
    }

    var patchedCopyModeLabel: String? {
        switch patchedCopyPatchState {
        case "silent": return "静默"
        case "keeptip": return "保留提示"
        default: return nil
        }
    }

    var bundledRuntimeDylibURL: URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("libExtraWeChatRuntime.dylib"),
           fm.fileExists(atPath: res.path) {
            return res
        }
        if let tools = toolsDir {
            let candidate = tools.appendingPathComponent("runtime/build/libExtraWeChatRuntime.dylib")
            if fm.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }

    var windowPrivacySupported: Bool {
        patchedCopyExists && patchedCopySupportsDYLD
    }

    var mainKeyPath: URL {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/ExtraWeChat/login_keys.tsv")
        if FileManager.default.fileExists(atPath: container.path) { return container }
        return dataDir.appendingPathComponent("login_keys.tsv")
    }

    var mainLogPath: URL {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/ExtraWeChat/login_persist.log")
        if FileManager.default.fileExists(atPath: container.path) { return container }
        return dataDir.appendingPathComponent("login_persist.log")
    }

    // MARK: - Refresh

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        errorMessage = nil

        let appURL = URL(fileURLWithPath: wechatPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            info = nil
            errorMessage = "找不到 \(wechatPath)。请在设置里修改微信路径。"
            return
        }

        info = readInfo(appURL)
        let running = isRunning(appPath: appURL.path)
        info?.running = running

        do {
            status = nil
            statusJSON = nil
            if let output = try? await runPython("install.py", ["status", "--app", wechatPath, "--json"]),
               let data = output.data(using: .utf8) {
                statusJSON = output
                status = try? JSONDecoder().decode(InstallStatus.self, from: data)
            }
            locate = nil
            locateJSON = nil
            if let output = try? await runPython("locate_revoke.py", ["--app", wechatPath, "--json"]),
               let data = output.data(using: .utf8) {
                locateJSON = output
                locate = try? JSONDecoder().decode(LocateInfo.self, from: data)
            }
        }

        mainSupportsDYLD = hasDYLDEntitlement(appURL.path)

        let copy = patchedCopyPath
        patchedCopyExists = FileManager.default.fileExists(atPath: copy.path)
        if patchedCopyExists {
            let copyInfo = readInfo(copy)
            patchedCopyVersion = copyInfo?.displayVersion
            patchedCopyBuild = copyInfo?.build
            patchedCopyRunning = isRunning(appPath: copy.path)
            patchedCopySupportsDYLD = hasDYLDEntitlement(copy.path)
            copyStatusJSON = try? await runPython("install.py", ["status", "--app", copy.path, "--json"])
            patchedCopyPatchState = nil
            if let data = try? Data(contentsOf: patchedCopyMarker),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                patchedCopyPatchState = object["variant"] as? String
            }
        } else {
            patchedCopyVersion = nil
            patchedCopyBuild = nil
            patchedCopyRunning = false
            patchedCopySupportsDYLD = false
            copyStatusJSON = nil
            patchedCopyPatchState = nil
        }

        await refreshInstances()
        loginKeys = readLoginKeys()
    }

    private func readInfo(_ appURL: URL) -> WeChatInfo? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        let bundle = plist["CFBundleIdentifier"] as? String ?? "com.tencent.xinWeChat"
        let short = plist["CFBundleShortVersionString"] as? String ?? "?"
        let build = plist["CFBundleVersion"] as? String ?? "?"
        let full = plist["WeChatBundleVersion"] as? String
        let receipt = appURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        let channel = FileManager.default.fileExists(atPath: receipt.path) ? "appStore" : "direct"
        return WeChatInfo(
            path: appURL.path,
            bundleID: bundle,
            shortVersion: short,
            build: build,
            fullVersion: full,
            channel: channel,
            running: isRunning(appPath: appURL.path)
        )
    }

    private func refreshInstances() async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: instancesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            instances = []
            return
        }
        var result: [InstanceInfo] = []
        for dir in entries {
            let app = dir.appendingPathComponent("WeChat.app", isDirectory: true)
            let home = dir.appendingPathComponent("home", isDirectory: true)
            guard fm.fileExists(atPath: app.path) else { continue }
            let info = readInfo(app)
            let running = isRunning(appPath: app.path)
            let dyld = hasDYLDEntitlement(app.path)
            let key = instanceKeyCandidates(home: home, bundleID: info?.bundleID ?? "")
                .first(where: { fm.fileExists(atPath: $0.path) })
                .flatMap { readKeyInfo($0) }
            result.append(InstanceInfo(
                id: dir.lastPathComponent,
                name: info?.shortVersion == nil ? dir.lastPathComponent : dir.lastPathComponent,
                appPath: app.path,
                homePath: home.path,
                bundleID: info?.bundleID ?? "",
                running: running,
                supportsDYLD: dyld,
                keyBytes: key?.bytes ?? 0,
                keyEntries: key?.entries ?? 0
            ))
        }
        instances = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func readLoginKeys() -> LoginKeySummary {
        let mainCandidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/ExtraWeChat/login_keys.tsv"),
            dataDir.appendingPathComponent("login_keys.tsv"),
        ]
        let main = mainCandidates.lazy.compactMap { self.readKeyInfo($0) }.first
        var instanceKeys: [KeyInfo] = []
        for instance in instances {
            let home = URL(fileURLWithPath: instance.homePath, isDirectory: true)
            for candidate in instanceKeyCandidates(home: home, bundleID: instance.bundleID) {
                if let key = readKeyInfo(candidate) {
                    instanceKeys.append(key)
                    break
                }
            }
        }
        return LoginKeySummary(main: main, instances: instanceKeys)
    }

    private func instanceKeyCandidates(home: URL, bundleID: String) -> [URL] {
        var out = [home.appendingPathComponent("Library/Application Support/ExtraWeChat/login_keys.tsv")]
        if !bundleID.isEmpty {
            out.append(home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/ExtraWeChat/login_keys.tsv"))
        }
        return out
    }

    private func readKeyInfo(_ url: URL) -> KeyInfo? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modified = attrs[.modificationDate] as? Date
        let entries: Int
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            entries = content.split(separator: "\n").filter { !$0.isEmpty }.count
        } else {
            entries = 0
        }
        return KeyInfo(path: url.path, bytes: bytes, entries: entries, modified: modified)
    }

    // MARK: - Tool execution

    func runPython(_ script: String, _ arguments: [String]) async throws -> String {
        guard let python = pythonURL else { throw ToolError.missingPython }
        guard let tools = toolsDir else { throw ToolError.missingTool(script) }
        let scriptURL = tools.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ToolError.missingTool(script)
        }
        let env = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }
        let path = scriptURL.path
        let args = arguments

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = python
            process.arguments = [path] + args
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                throw ToolError.failed(error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw ToolError.failed(output.isEmpty ? "命令失败（退出码 \(process.terminationStatus)）" : output)
            }
            return output
        }.value
    }

    /// Run a bundled Python tool as root through the standard macOS admin
    /// authorization dialog. WeChat.app lives in /Applications and is owned by
    /// root:wheel, so a normal user process can never write it even when App
    /// Management has been granted.
    func runPythonAsAdmin(_ script: String, _ arguments: [String]) async throws -> String {
        guard let python = pythonURL else { throw ToolError.missingPython }
        guard let tools = toolsDir else { throw ToolError.missingTool(script) }
        let scriptURL = tools.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ToolError.missingTool(script)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let command = "HOME=\(shellQuote(home)) "
            + ([python.path, scriptURL.path] + arguments).map(shellQuote).joined(separator: " ")
            + " 2>&1"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        with timeout of 600 seconds
            do shell script "\(escaped)" with administrator privileges
        end timeout
        """

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                throw ToolError.failed(error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                if output.contains("-128") || output.localizedCaseInsensitiveContains("User canceled") {
                    throw ToolError.failed("已取消管理员授权。")
                }
                throw ToolError.failed(output.isEmpty ? "管理员命令失败（退出码 \(process.terminationStatus)）" : output)
            }
            return output
        }.value
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func hasDYLDEntitlement(_ appPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", appPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains("allow-dyld-environment-variables")
    }

    func isRunning(appPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", appPath + "/Contents/MacOS/WeChat"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Anti-revoke

    func installAntiRevoke(variant: String, allowDYLD: Bool) async {
        await perform("正在安装消息防撤回…") {
            if self.isRunning(appPath: self.wechatPath) {
                throw ToolError.failed("微信仍在运行。请先完全退出微信（⌘Q，并等待 helper 退出）。")
            }
            var args = ["install", "--app", self.wechatPath, "--variant", variant]
            if allowDYLD { args.append("--allow-dyld-env") }
            return try await self.runPythonAsAdmin("install.py", args)
        }
    }

    func restoreAntiRevoke() async {
        await perform("正在还原微信…") {
            if self.isRunning(appPath: self.wechatPath) {
                throw ToolError.failed("微信仍在运行。请先完全退出微信。")
            }
            return try await self.runPythonAsAdmin("install.py", ["restore", "--app", self.wechatPath])
        }
    }

    func createTestCopy(variant: String) async {
        let testDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/ExtraWeChat/Test", isDirectory: true)
        let output = testDir.appendingPathComponent("WeChat-Test.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        await perform("正在创建测试副本…") {
            try await self.runPython("patch_copy.py", [
                "--app", self.wechatPath,
                "--output", output.path,
                "--variant", variant,
                "--force",
            ])
        }
        toast = "测试副本：\(output.path)"
    }

    // MARK: - Patched copy (no App Management required)

    func createPatchedCopy(variant: String) async {
        if isRunning(appPath: wechatPath) {
            errorMessage = "请先完全退出原微信（⌘Q，并等待 helper 退出），再创建补丁副本。"
            return
        }
        if isRunning(appPath: patchedCopyPath.path) {
            errorMessage = "补丁副本正在运行。请先退出补丁副本，再更新。"
            return
        }
        let output = patchedCopyPath
        await perform("正在创建补丁副本…") {
            try await self.runPython("patch_copy.py", [
                "--app", self.wechatPath,
                "--output", output.path,
                "--variant", variant,
                "--allow-dyld-env",
                "--force",
            ])
        }
        if errorMessage == nil {
            let marker: [String: Any] = ["variant": variant, "path": output.path]
            if let data = try? JSONSerialization.data(withJSONObject: marker) {
                try? data.write(to: patchedCopyMarker, options: .atomic)
            }
            launchPatchedCopy()
        }
    }

    func launchPatchedCopy() {
        let copy = patchedCopyPath
        guard FileManager.default.fileExists(atPath: copy.path) else {
            errorMessage = "还没有补丁副本。请先点击“创建防撤回副本”。"
            return
        }
        if isRunning(appPath: wechatPath) {
            errorMessage = "原微信仍在运行。请先完全退出原微信，再启动补丁副本。"
            return
        }
        if isRunning(appPath: copy.path) {
            activatePatchedCopy()
            return
        }
        var args = ["-n"]
        if windowPrivacy {
            guard let runtime = bundledRuntimeDylibURL else {
                errorMessage = "找不到窗口隐私组件。请重新构建/安装 ExtraWeChat。"
                return
            }
            guard hasDYLDEntitlement(copy.path) else {
                errorMessage = "补丁副本没有启用 DYLD。请先「更新副本」再开启窗口隐私。"
                return
            }
            args += ["--env", "DYLD_INSERT_LIBRARIES=\(runtime.path)"]
            args += ["--env", "EXTRAWECHAT_WINDOW_PRIVACY=1"]
        }
        args.append(copy.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        do {
            try process.run()
            patchedCopyExists = true
            patchedCopyRunning = true
            toast = windowPrivacy ? "已启动补丁副本（窗口隐私）" : "已启动补丁副本"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restartPatchedCopy() async {
        await quitPatchedCopy()
        launchPatchedCopy()
    }

    func activatePatchedCopy() {
        let apps = runningApplications(at: patchedCopyPath.path)
        guard let app = apps.first else {
            toast = "补丁副本没有在运行"
            return
        }
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    func revealPatchedCopy() {
        let copy = patchedCopyPath
        if FileManager.default.fileExists(atPath: copy.path) {
            NSWorkspace.shared.activateFileViewerSelecting([copy])
        } else {
            NSWorkspace.shared.open(copy.deletingLastPathComponent())
        }
    }

    // MARK: - Instances

    func createInstance(name: String, variant: String, loginPersistence: Bool) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "实例名称不能为空。"
            return
        }
        let base = slugify(trimmed)
        let slug = base.isEmpty ? "instance-\(Int(Date().timeIntervalSince1970))" : base
        let app = instancesDir.appendingPathComponent(slug).appendingPathComponent("WeChat.app")
        let home = instancesDir.appendingPathComponent(slug).appendingPathComponent("home")
        if FileManager.default.fileExists(atPath: app.path) {
            errorMessage = "实例 \(slug) 已存在。请换一个名称或先删除。"
            return
        }
        try? FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        await perform("正在创建实例 \(name)…") {
            var args = [
                "--app", self.wechatPath,
                "--output", app.path,
                "--variant", variant,
                "--clone", slug,
                "--instance-home", home.path,
            ]
            if loginPersistence { args.append("--allow-dyld-env") }
            return try await self.runPython("patch_copy.py", args)
        }
    }

    func launchInstance(_ instance: InstanceInfo, loginPersistence: Bool) {
        if loginPersistence {
            guard instance.supportsDYLD else {
                errorMessage = "这个实例没有启用 DYLD 权限。请删除后用“登录态保持”重新创建。"
                return
            }
            launchWithDYLD(appPath: instance.appPath, homePath: instance.homePath)
        } else {
            launchWithOpen(appPath: instance.appPath, homePath: instance.homePath)
        }
    }

    func deleteInstance(_ instance: InstanceInfo) async {
        let app = URL(fileURLWithPath: instance.appPath, isDirectory: true).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: app)
        await refresh()
        toast = "已删除实例 \(instance.name)"
    }

    private func launchWithOpen(appPath: String, homePath: String?) {
        if isRunning(appPath: appPath) {
            errorMessage = "该实例已在运行。"
            return
        }
        var args = ["-n"]
        if let homePath {
            args += ["--env", "CFFIXED_USER_HOME=\(homePath)", "--env", "HOME=\(homePath)"]
        }
        args.append(appPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        do {
            try process.run()
            toast = "已启动实例"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func launchWithDYLD(appPath: String, homePath: String?) {
        guard !isRunning(appPath: appPath) else {
            errorMessage = "微信仍在运行。请先完全退出。"
            return
        }
        guard let dylib = bundledDylibURL else {
            errorMessage = "找不到登录态 dylib。请先运行 tools/login_persist/build.sh，或使用打包后的 App。"
            return
        }
        let binary = URL(fileURLWithPath: appPath, isDirectory: true)
            .appendingPathComponent("Contents/MacOS/WeChat")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            errorMessage = "找不到微信可执行文件。"
            return
        }
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = dylib.path
        env["EXTRAWECHAT_LOGIN_DEBUG"] = "1"
        if let homePath {
            env["CFFIXED_USER_HOME"] = homePath
            env["HOME"] = homePath
        }
        let process = Process()
        process.executableURL = binary
        process.environment = env
        let logURL = dataDir.appendingPathComponent("launch.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            toast = "已带登录态保持启动。日志：\(mainLogPath.path)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Login persistence

    func enableLoginPersistenceOnMain(variant: String) async {
        await installAntiRevoke(variant: variant, allowDYLD: true)
        toast = "主微信已启用登录态保持（重启后生效）"
    }

    func launchMain(loginPersistence: Bool) {
        if loginPersistence {
            guard mainSupportsDYLD else {
                errorMessage = "主微信还没有 allow-dyld-env 权限。请先点击“启用登录态保持”。"
                return
            }
            launchWithDYLD(appPath: wechatPath, homePath: nil)
        } else {
            launchWithOpen(appPath: wechatPath, homePath: nil)
        }
    }

    func clearLoginKeys() async {
        let fm = FileManager.default
        var removed = 0
        var paths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/ExtraWeChat/login_keys.tsv"),
            dataDir.appendingPathComponent("login_keys.tsv"),
        ]
        for instance in instances {
            let home = URL(fileURLWithPath: instance.homePath, isDirectory: true)
            paths += instanceKeyCandidates(home: home, bundleID: instance.bundleID)
        }
        for path in paths where fm.fileExists(atPath: path.path) {
            if (try? fm.removeItem(at: path)) != nil { removed += 1 }
        }
        await refresh()
        toast = removed > 0 ? "已清除 \(removed) 个 key 文件" : "没有找到已保存的 key"
    }

    private func runningApplications(at appPath: String) -> [NSRunningApplication] {
        let target = URL(fileURLWithPath: appPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat")
            .filter { app in
                guard let url = app.bundleURL else { return false }
                return url.resolvingSymlinksInPath().standardizedFileURL.path == target
            }
    }

    func quitWeChat() async {
        let apps = runningApplications(at: wechatPath)
        guard !apps.isEmpty else {
            toast = "原微信没有在运行"
            return
        }
        for app in apps { app.terminate() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if isRunning(appPath: wechatPath) {
            errorMessage = "原微信还没有完全退出，请手动 ⌘Q 并等待 helper 结束。"
        } else {
            toast = "原微信已退出"
        }
    }

    func quitPatchedCopy() async {
        let apps = runningApplications(at: patchedCopyPath.path)
        guard !apps.isEmpty else {
            toast = "补丁副本没有在运行"
            return
        }
        for app in apps { app.terminate() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if isRunning(appPath: patchedCopyPath.path) {
            errorMessage = "补丁副本还没有完全退出，请手动 ⌘Q。"
        } else {
            patchedCopyRunning = false
            toast = "补丁副本已退出"
        }
    }

    // MARK: - Misc

    func developerReport() -> String {
        let summary = profileSummary()
        var lines: [String] = []
        lines.append("ExtraWeChat developer report")
        lines.append("app_version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        lines.append("macos: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("arch: \(ProcessInfo.processInfo.machineHardwareName)")
        lines.append("wechat_path: \(wechatPath)")
        lines.append("wechat_build: \(info?.build ?? "?")")
        lines.append("match: \(locate?.match ?? "?")")
        lines.append("arch_target: \(locate?.arch ?? "?")")
        lines.append("generation: \(locate?.generation ?? "?")")
        lines.append("silent_state: \(locate?.silent_state ?? "?")")
        lines.append("keeptip_state: \(locate?.keeptip_state ?? "?")")
        lines.append("profile_builds: \(summary?.builds ?? 0)")
        lines.append("profile_generations: \(summary?.generations ?? 0)")
        lines.append("copy_exists: \(patchedCopyExists)")
        lines.append("copy_running: \(patchedCopyRunning)")
        lines.append("copy_build: \(patchedCopyBuild ?? "?")")
        lines.append("copy_supports_dyld: \(patchedCopySupportsDYLD)")
        lines.append("copy_needs_update: \(patchedCopyNeedsUpdate)")
        lines.append("runtime_dylib: \(bundledRuntimeDylibURL?.path ?? "missing")")
        lines.append("profiles: \(profilesPath?.path ?? "missing")")
        lines.append("")
        lines.append("locate_json:")
        lines.append(locateJSON ?? "(missing)")
        lines.append("")
        lines.append("status_json:")
        lines.append(statusJSON ?? "(missing)")
        lines.append("")
        lines.append("copy_status_json:")
        lines.append(copyStatusJSON ?? "(missing)")
        return lines.joined(separator: "\n")
    }

    func copyDeveloperReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(developerReport(), forType: .string)
        toast = "开发者报告已复制"
    }

    func exportDeveloperReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ExtraWeChat-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try developerReport().write(to: url, atomically: true, encoding: .utf8)
            toast = "已导出 \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkForWeChatUpdate() async {
        let plist = URL(fileURLWithPath: wechatPath)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let build = object["CFBundleVersion"] as? String
        else { return }
        guard let current = info?.build, build != current else { return }
        toast = "微信已更新到 \(build)，请重建补丁副本"
        await refresh()
    }

    func checkProfileUpdates() async {
        busy = true
        log = ""
        errorMessage = nil
        defer { busy = false }
        do {
            let output = try await runPython("profile_update.py", ["update", "--json"])
            log = output
            if let data = output.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let status = object["status"] as? String ?? "unknown"
                let builds = object["remote_builds"] as? Int ?? 0
                if status == "installed" || status == "up-to-date" {
                    toast = status == "installed"
                        ? "适配表已更新（\(builds) 个构建）"
                        : "适配表已是最新"
                } else {
                    toast = "适配表状态：\(status)"
                }
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            log = error.localizedDescription
        }
    }

    func switchCopyMode(variant: String) async {
        guard patchedCopyExists else {
            errorMessage = "还没有补丁副本。"
            return
        }
        if isRunning(appPath: patchedCopyPath.path) {
            errorMessage = "补丁副本正在运行。请先退出副本，再切换模式。"
            return
        }
        if isRunning(appPath: wechatPath) {
            errorMessage = "原微信仍在运行。请先完全退出原微信。"
            return
        }
        await perform("正在切换补丁模式…") {
            try await self.runPython("switch_mode.py", [
                "--app", self.patchedCopyPath.path,
                "--variant", variant,
            ])
        }
        if errorMessage == nil {
            let marker: [String: Any] = ["variant": variant, "path": patchedCopyPath.path]
            if let data = try? JSONSerialization.data(withJSONObject: marker) {
                try? data.write(to: patchedCopyMarker, options: .atomic)
            }
            launchPatchedCopy()
        }
    }

    func openProfilesFile() {
        guard let url = profilesPath else {
            errorMessage = "找不到 revoke_profiles.json"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openToolsFolder() {
        guard let tools = toolsDir else {
            errorMessage = "找不到 tools 目录"
            return
        }
        NSWorkspace.shared.open(tools)
    }

    func verifySignatures() async {
        verifyingSignatures = true
        defer { verifyingSignatures = false }
        var lines: [String] = []
        let targets = [("WeChat", wechatPath), ("Copy", patchedCopyPath.path)]
        for (label, path) in targets where FileManager.default.fileExists(atPath: path) {
            let result = Process()
            result.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            result.arguments = ["--verify", "--deep", "--strict", "--verbose=2", path]
            let pipe = Pipe()
            result.standardOutput = pipe
            result.standardError = pipe
            do {
                try result.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                result.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                lines.append("\(label): \(result.terminationStatus == 0 ? "OK" : "FAILED")")
                if !out.isEmpty { lines.append(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
            } catch {
                lines.append("\(label): ERROR \(error.localizedDescription)")
            }
        }
        signatureReport = lines.joined(separator: "\n")
    }

    func openLog() {
        let fm = FileManager.default
        if fm.fileExists(atPath: mainLogPath.path) {
            NSWorkspace.shared.open(mainLogPath)
        } else {
            NSWorkspace.shared.open(dataDir)
        }
    }

    func openKeyFolder() {
        let dir = mainKeyPath.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.open(dir)
        } else {
            NSWorkspace.shared.open(dataDir)
        }
    }

    func openBackupFolder() {
        NSWorkspace.shared.open(backupDir)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func openAppManagementSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func copyDiagnostics() {
        let text = """
        ExtraWeChat diagnostics
        WeChat: \(info?.displayVersion ?? "?") \(info?.channelTitle ?? "")
        Path: \(wechatPath)
        Running: \(info?.running == true)
        Patch: \(status?.patch_state ?? "?")
        Generation: \(locate?.generation ?? "?")
        Silent VA: \(formatHex(locate?.silent_va))
        Keeptip VA: \(formatHex(locate?.keeptip_va))
        Backup: \(status?.backup_dir ?? "?") (\(status?.has_backup == true ? "yes" : "no"))
        Main DYLD: \(mainSupportsDYLD)
        Login keys: main=\(loginKeys.main?.entries ?? 0) instances=\(loginKeys.instances.count)
        Instances: \(instances.count)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast = "诊断信息已复制"
    }

    private func perform(_ title: String, _ operation: @escaping () async throws -> String) async {
        busy = true
        log = ""
        errorMessage = nil
        defer { busy = false }
        do {
            let output = try await operation()
            log = output
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            log = error.localizedDescription
        }
    }

    private func slugify(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let raw = String(scalars)
        let collapsed = raw.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
