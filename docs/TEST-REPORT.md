# 副本测试报告（2026-10-27）

本报告记录「不改 `/Applications/WeChat.app`，只在副本上验证」的过程。
所有测试都在 `/private/var/folders/.../opencode/` 的临时目录完成，测试结束后副本已删除；
**主微信没有被修改**。

## 0. 环境

| 项目 | 值 |
| --- | --- |
| macOS | 27.0.1 |
| 芯片 | Apple Silicon（arm64） |
| SIP | `System Integrity Protection status: enabled.` |
| 微信 | 4.1.15.35，`CFBundleVersion` 270115 |
| 渠道 | App Store（存在 `Contents/_MASReceipt/receipt`） |
| Bundle ID | `com.tencent.xinWeChat` |
| 主二进制 | `Contents/MacOS/WeChat`，184,800 字节 |
| 核心 dylib | `Contents/Resources/wechat.dylib`，335 MB universal；arm64 切片 169 MB |
| App 大小 | 1.4 GB |
| 数据 | `~/Library/Containers/com.tencent.xinWeChat`，约 7 GB |

签名信息：

```
Executable=.../WeChat
Identifier=com.tencent.xinWeChat
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory ... flags=0x10000(runtime)
Authority=Apple Mac OS Application Signing
TeamIdentifier=5A4RE8SF68
```

entitlements（节选）：

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key>
<array><string>5A4RE8SF68.com.tencent.xinWeChat</string></array>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.device.camera</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
...
```

## 1. 只读定位

命令：

```bash
python3 tools/locate_revoke.py --app /Applications/WeChat.app
```

结果：

```
===== WeChat anti-revoke locator =====
WeChat:        4.1.15 (build 270115), appStore, com.tencent.xinWeChat
Full version:  4.1.15.35
Host arch:     arm64  (patch targets arm64)
Generation:    4.1.13+ (269574+)  (newmsgid field [x19,#0x1c8])
parseRevokeXML entry E: 0x4bbaf6c
silent  VA:    0x4bbb1dc  40100034 -> 82000014  [pristine]
keeptip VA:    0x4bbb97c  60E600F9 -> 7FE600F9  [pristine]
STP prologue:  ok
```

唯一命中，未修改任何文件。

反汇编（用 `lldb` 对抽取的 arm64 切片）：

```
0x4bbb1d8  bl     0x47468f0
0x4bbb1dc  cbz    w0, 0x4bbb3e4        ; 原始 silent 点
...
0x4bbb978  bl     0x4a707a4
0x4bbb97c  str    x0, [x19, #0x1c8]    ; 原始 keeptip 点
```

## 2. 副本 A：保留沙盒 + 新 bundle ID（失败）

目的：验证「只改 bundle ID」能否多开。

步骤：

1. `ditto /Applications/WeChat.app <temp>/WeChat-Test.app`
2. 修改 `Contents/Info.plist`：
   - `CFBundleIdentifier` → `com.extrawechat.test.wechat`
   - `CFBundleDisplayName` → `WeChat Test`
3. patch silent 点。
4. 逐对象保留 entitlements + 注入两个 Hardened Runtime 例外，重签。
5. `codesign --verify --deep --strict` 通过。
6. 启动。

结果：**退出 255**，没有出现主窗口。日志关键行：

```
bootstrap_check_in 5A4RE8SF68.com.extrawechat.test.wechat.crashpad...
    Permission denied (1100)
failed to attach inherited crashpad handler port
[wcdyf] configuration updated download='.../Library/Containers/com.tencent.xinWeChat/...
```

原因：新 bundle ID 与保留的 `com.apple.application-identifier` / app group 不一致；
crashpad 的 mach service 和 sandbox 扩展无法建立。说明「只改 bundle ID」不够。

## 3. 副本 B：新 bundle ID + 去沙盒（成功）

在副本 A 基础上，去掉所有代码对象的：

- `com.apple.security.app-sandbox`
- `com.apple.application-identifier`
- `com.apple.security.application-groups`

保留其他权限，注入：

- `com.apple.security.cs.disable-library-validation`
- `com.apple.security.cs.allow-unsigned-executable-memory`

重签并验证通过。启动时使用独立 home：

```bash
CFFIXED_USER_HOME=<instance-home> HOME=<instance-home> \
  <temp>/WeChat-Test.app/Contents/MacOS/WeChat
```

结果：**主进程存活**，辅助进程树启动：

```
WeChat-Test.app/Contents/MacOS/WeChat
WeChat-Test.app/Contents/Frameworks/crashpad_handler ...
WeChat-Test.app/Contents/MacOS/WeChatAppEx.app/Contents/MacOS/WeChatAppEx ...
WeChat-Test.app/.../WeChatAppEx Helper ...
```

数据目录落在独立 home：

```
<instance-home>/Documents/app_data
<instance-home>/Library/Containers/com.extrawechat.test.wechat/Data/Documents/xwechat_files
```

原微信 `com.tencent.xinWeChat` 仍在运行，未受影响。这说明**多开的技术路径成立**：
复制 App + 新 bundle ID + 去沙盒 + 独立 `CFFIXED_USER_HOME`。

> 注意：这是独立数据目录的全新实例，需要重新登录；不是旧插件那种同数据目录的第二窗口。

## 4. 副本 C：保留原 bundle ID + 沙盒（主应用模拟）

目的：验证「正式 patch 主 App」时，保留原 entitlements 的重签是否会被 macOS 接受。

步骤：

1. `ditto /Applications/WeChat.app <temp>/WeChat-MainCopy.app`
2. patch silent 点。
3. 逐对象保留 entitlements（含 app-sandbox/application-identifier/app-group），
   仅去掉 `com.apple.developer.*`，注入两个 Hardened Runtime 例外。
4. 重签 124 个代码对象（23 个带 entitlements），`codesign --verify --deep --strict` 通过。
5. 在原微信运行时启动副本。

结果：**退出 255**，没有 AMFI/签名错误；日志显示已加载副本内的 `wechat.dylib`（补丁已写入），
并访问原容器：

```
[wcdyf] configuration updated download='.../Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/...
```

这更像是**单实例保护**（原微信已持有 `app_data/lock/lock.ini`）导致的主动退出，而不是签名被拒。
要确认「退出原微信后能否正常启动」，需要一次不运行主微信的验收；本次没有执行，以免打断用户
正在使用的微信。

## 5. PoC 脚本全流程

命令：

```bash
python3 tools/patch_copy.py \
  --app /Applications/WeChat.app \
  --output <temp>/WeChat-PoC.app \
  --variant silent
```

输出摘要：

```
[info] WeChat 4.1.15 build 270115 (appStore, com.tencent.xinWeChat)
[copy] ditto …
[locate] 4.1.13+ (269574+), E=0x4bbaf6c, silent=0x4bbb1dc, keeptip=0x4bbb97c
[silent] VA 0x4bbb1dc -> 0xf8c71dc: 40100034 -> 82000014
[sign] 124 code objects (23 with entitlements)
...
WeChat-PoC.app: valid on disk
WeChat-PoC.app: satisfies its Designated Requirement
[done] copy is patched, re-signed and verified.
```

再次只读定位副本：

```
silent  VA: 0x4bbb1dc  82000014 -> 82000014  [patched-silent]
keeptip VA: 0x4bbb97c  60E600F9 -> 7FE600F9  [pristine]
```

签名验证：

```
codesign --verify --deep --strict ...; echo $?
0
```

根 entitlements 仍包含：

```
com.apple.application-identifier = 5A4RE8SF68.com.tencent.xinWeChat
com.apple.security.app-sandbox = true
com.apple.security.application-groups = [5A4RE8SF68.com.tencent.xinWeChat]
com.apple.security.cs.disable-library-validation = true
com.apple.security.cs.allow-unsigned-executable-memory = true
```

## 6. Accessibility 检查

`AXIsProcessTrusted()` 返回 true。用 AX API 遍历微信：

```
AXApplication 微信
  AXWindow/AXDialog (无标题)
  AXWindow/AXDialog 微信
    AXButton/AXCloseButton
    AXButton/AXFullScreenButton
    AXButton/AXMinimizeButton
  AXMenuBar ...
```

主窗口内没有聊天列表、消息文本或输入框。结论：**不能靠 AX 做自动回复/远程控制**。

## 7. 未完成 / 待用户验收

- [ ] 退出主微信后，启动 patched 的「原 bundle ID + 沙盒」副本，确认能进入登录/主界面。
- [ ] 登录第二个账号（多开实例），互发消息并撤回，验证 silent 变体。
- [ ] 验证 keeptip 变体：私聊消息保留 + 提示显示；群聊消息保留，提示是否出现。
- [ ] 执行 `restore`，把补丁点写回原始字节，重签并确认微信恢复原样。
- [ ] 在正式安装到 `/Applications/WeChat.app` 前，完整备份聊天数据。

## 8. 测试后清理

- 删除临时副本 `WeChat-Test.app`、`WeChat-MainCopy.app`、`WeChat-PoC.app`；
- 删除测试用 `CFFIXED_USER_HOME`；
- 删除测试创建的 `~/Documents/app_data`（只包含测试初始化的 crashinfo/loader/log，无聊天数据）；
- 没有修改 `/Applications/WeChat.app`。

---

## 9. 安装器与 GUI（2026-10-27 补充）

### 9.1 `tools/install.py` 副本测试

- 在 `/Applications/WeChat.app` 的副本上执行 `install.py install --variant silent`；
- 124 个代码对象重签，`codesign --verify --deep --strict` 通过；
- `status --json` 正确报告 `patch_state=silent`、备份路径、构建号；
- `restore` 写回原始 `wechat.dylib` 并重签，`status` 回到 `pristine`，签名通过；
- `install --variant none --allow-dyld-env` 后主 App entitlements 包含
  `com.apple.security.cs.allow-dyld-environment-variables` 与 `app-sandbox`；
- `restore` 后 `allow-dyld-env` 被移除，`app-sandbox` 保留，签名通过。

### 9.2 GUI 构建

- `./scripts/build_app.sh` 成功生成 `build/ExtraWeChat.app` 与
  `build/ExtraWeChat-0.1.0-arm64.zip`；
- App 为 ad-hoc 签名，`codesign --verify --deep --strict` 通过；
- GUI 已实际启动，读取到：
  - 微信 4.1.15.35 / build 270115 / App Store；
  - 防撤回状态 `pristine`；
  - 补丁点 `silent=0x4bbb1dc`、`keeptip=0x4bbb97c`；
  - Python `/usr/bin/python3`、内置 tools、login dylib 路径；
- 概览、防撤回、多开、登录态、诊断页面均已截图（见 `docs/screenshots/`）；
- App 图标使用用户提供的 `WeChat.png` 生成，窗口内概览页和侧栏图标同步使用该图标，
  菜单栏使用同源的模板图标；
- README 顶部直接引用原始透明 PNG `Github_readmeTop_EWC.png`，未做颜色/透明通道处理；
- 菜单栏图标改为从 `Contents/Resources/MenuBarIcon.png` 直接加载，避免 SwiftPM
  `Bundle.module` 在不同 CI 打包布局下崩溃。

### 9.3 未完成

- 在主 `/Applications/WeChat.app` 上实际安装（需要用户退出微信并确认）；
- 主 App 安装后启动 / 真实撤回消息 / 还原的完整验收；
- 真实账号的 autoauth key 捕获与注入验证；
- GUI 的 App 管理权限引导在目标系统上的实际点击验证。

---

## 10. v0.1.1：权限与 pkg（2026-10-27）

### 10.1 权限诊断

- 主微信的 `wechat.dylib` 属主为 `root:wheel`、权限 `0644`，普通用户进程无法写入；
- TCC「App 管理」中 `ExtraWeChat.app` 已启用，但仍会得到
  `PermissionError: [Errno 13] Permission denied`；
- 结论：Errno 13 是 Unix 文件权限，不是 TCC；必须通过 root 执行安装/还原。

### 10.2 修复

- GUI 的「安装到主微信 / 还原微信」改为通过 macOS 管理员授权对话框执行
  （`osascript ... with administrator privileges`）；
- CLI 文档改为 `sudo python3 tools/install.py ...`；
- `install.py` 捕获权限错误并输出 App 管理 / root 两层权限说明，不再抛原始 traceback。

### 10.3 pkg

- 新增 `scripts/build_pkg.sh`，生成
  `build/ExtraWeChat-0.1.1-arm64.pkg`；
- pkg 安装到 `/Applications/ExtraWeChat.app`，postinstall 清理 quarantine 并设置
  `root:wheel`；
- 展开 pkg payload 后 `codesign --verify --deep --strict` 通过；
- 无 Developer ID Installer 证书，pkg 未签名、未公证；需要右键打开或
  `sudo installer -pkg ... -target /`。

### 10.4 待验收

- 通过 GUI 管理员授权在真实主微信上完成安装；
- 真实撤回消息验证；
- 通过 GUI 管理员授权完成还原。

---

## 11. v0.1.2：TCC 限制与补丁副本（2026-10-28）

### 11.1 主 App 的最终结论

- 普通用户：`Errno 13 Permission denied`（`wechat.dylib` 属主 root:wheel）；
- 管理员授权后的 root 子进程：仍被 `kTCCServiceSystemPolicyAppBundles` 拦截；
- 即使「App 管理」中 ExtraWeChat 已启用，`osascript` / `python3` 子进程也不会继承授权；
- 结论：**不保证能修改 `/Applications/WeChat.app`**，不能把主 App 安装作为唯一方案。

### 11.2 补丁副本（已验证可用）

- 用 `patch_copy.py` 在 `~/Applications/WeChatExtra.app` 创建副本；
- 保留原 bundle ID / 沙盒容器，账号和聊天记录直接复用；
- 已应用 `keeptip` 补丁，`codesign --verify --deep --strict` 通过；
- 在原微信完全退出后成功启动，显示同一账号，可正常进入；
- 该方案不需要 root、不需要 App 管理、不修改 `/Applications/WeChat.app`。

### 11.3 GUI

- 「消息防撤回」新增补丁副本卡片：创建/更新并启动、启动、退出、Finder 显示；
- 副本与原微信不能同时运行；
- 主 App 安装保留为高级选项，并在文档中明确 TCC 限制。

---

## 12. v0.1.3：真实撤回验收与 UI 优化（2026-10-29）

### 12.1 真实撤回验收

- 用户在 `~/Applications/WeChatExtra.app` 补丁副本中完成真实撤回测试；
- 模式：`keeptip`；
- 结果：撤回后消息保留，防撤回生效；
- 主 `/Applications/WeChat.app` 未修改，签名仍然有效。

### 12.2 UI 优化

- 防撤回页改为状态 Hero：直接显示模式、副本状态和主操作按钮；
- 防撤回模式改为两张可点击卡片（静默 / 提示），不再使用 radio group；
- 副本管理集中到单独卡片：创建/更新、打开、退出、Finder；
- 主微信安装移入「高级」折叠区，默认不展示；
- 技术地址、备份路径等移入「诊断」页；
- 新增副本版本检测：主微信更新后显示「副本需要更新」；
- 菜单栏新增副本状态、启动/打开/退出副本、更新入口；
- 概览页状态同步显示原微信和副本状态；
- 深色 / 浅色外观均实际检查，文字与卡片对比度正常。

截图见 `docs/screenshots/overview.png`、`anti-revoke.png`、`diagnostics.png`。

---

## 13. v0.1.4：扩大微信版本适配（2026-10-30）

### 13.1 适配表

- 新增 `tools/revoke_profiles.json`，按 `CFBundleVersion` 保存 42 个微信 4.x
  arm64 构建的 silent / keeptip 补丁点；
- 覆盖 4.1.10 ~ 4.1.15.55（268575–270135）；
- 268880 仅支持 silent；269602 使用分类函数桩 + parseRevokeXML 的特殊配置；
- 未收录的构建仍可用 3 代 arm64 几何签名自动定位。

### 13.2 验证

- 270115 上 `match=profile` 与 `--force-scan` 的 `match=signature` 地址完全一致；
- 在独立 `wechat.dylib` 副本上完成 pristine → silent → keeptip → pristine 字节级测试；
- `python3 -m unittest discover -s tests` 共 8 项通过；
- GUI / 安装脚本改为读取 `entries`，同时保留旧字节校验；
- 未适配构建会在 GUI 显示「当前微信构建暂未适配」，不会写入。

### 13.3 平台范围

- 仅 Apple Silicon（arm64）；
- App 目标 macOS 13+，本机 macOS 27.0.1 实测；
- Intel、微信 3.8.x、4.1.7 不支持。

### 13.4 未验证

- 42 个构建中只有 270115 做了真实撤回测试；
- 其余构建的地址来自 zengtianli/WeChatTweak 的公开配置（AGPL-3.0），
  已做格式和原始字节校验，但未逐一在真机启动验证。

---

## 14. v0.1.5：窗口隐私与主题（2026-10-30）

### 14.1 窗口隐私

- 新增 `libExtraWeChatRuntime.dylib`，通过 `DYLD_INSERT_LIBRARIES` 注入补丁副本；
- hook `NSWindow` 创建 / orderFront / orderWindow / setSharingType，并监听窗口事件；
- 用 `CGWindowListCopyWindowInfo` 对比：
  - 未注入：微信主窗口和聊天窗口 `kCGWindowSharingState=1`；
  - 注入后：主窗口 / 聊天窗口变为 `0`；
  - 屏幕顶部 33px 的系统菜单栏窗口仍为 `1`，不属于聊天内容；
- 未修改 `/Applications/WeChat.app`，不涉及 TCC / root。

限制：录屏/共享软件和 macOS 版本可能影响效果，不能当作安全保证。

### 14.2 主题

- 新增 `AppTheme`：微信绿、深海蓝、日落橙、紫罗兰、石墨灰；
- 主题影响侧栏、卡片、按钮、页面背景和增强页图标；
- 设置页提供主题卡片选择；
- 深色模式实际检查，浅色模式沿用同一套基础色 + accent。

### 14.3 尚未完成

- 自定义撤回提示、撤回记录、关键词提醒仍为规划中；
- 自动领红包未纳入默认计划（资金自动化风险高）；
- 主题浅色模式和 0.1.5 截图待补。
