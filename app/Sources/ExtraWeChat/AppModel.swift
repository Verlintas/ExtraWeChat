import AppKit
import Combine
import Foundation

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
    @Published var busy = false
    @Published var refreshing = false
    @Published var log = ""
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
            if let output = try? await runPython("install.py", ["status", "--app", wechatPath, "--json"]),
               let data = output.data(using: .utf8) {
                status = try? JSONDecoder().decode(InstallStatus.self, from: data)
            }
            if let output = try? await runPython("locate_revoke.py", ["--app", wechatPath, "--json"]),
               let data = output.data(using: .utf8) {
                locate = try? JSONDecoder().decode(LocateInfo.self, from: data)
            }
        }

        mainSupportsDYLD = hasDYLDEntitlement(appURL.path)
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

    func quitWeChat() async {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat")
        guard !apps.isEmpty else {
            toast = "微信没有在运行"
            return
        }
        for app in apps { app.terminate() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if isRunning(appPath: wechatPath) {
            errorMessage = "微信还没有完全退出，请手动 ⌘Q 并等待 helper 结束。"
        } else {
            toast = "微信已退出"
        }
    }

    // MARK: - Misc

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
