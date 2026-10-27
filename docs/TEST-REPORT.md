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
