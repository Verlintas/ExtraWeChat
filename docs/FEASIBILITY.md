# ExtraWeChat 可行性报告

> 目标：评估能否在 **微信 macOS 4.1.15（App Store 版，build 270115）** 上重新实现
> [TKkk-iOSer/WeChatPlugin-MacOS](https://github.com/TKkk-iOSer/WeChatPlugin-MacOS) 的核心功能。
>
> 测试环境：macOS 27.0.1、Apple Silicon（arm64）、SIP 已开启、微信 4.1.15.35
> （`CFBundleVersion` = 270115，`com.tencent.xinWeChat`，App Store 渠道）。
>
> 结论日期：2026-10-27。本文只描述本机验证结果；微信更新后所有地址都可能变化。

---

## 1. 结论摘要

旧版「微信小助手」的核心是 **Objective-C runtime 注入 + method swizzling**。微信 4.x 已经用
Qt/C++ 重写，消息逻辑整体搬进 `Contents/Resources/wechat.dylib`，旧的类名、方法名和注入路径全部
失效。**不能直接把旧插件重新编译到 4.x 上。**

在本机 4.1.15 上，实际可行的能力如下：

| 能力 | 可行性 | 结论 |
| --- | :---: | --- |
| 消息防撤回（静默：保留消息，不显示提示） | ✅ 可行 | 二进制补丁，已在副本上完成补丁 + 重签 + 启动验证 |
| 消息防撤回（留提示：保留消息，私聊仍显示「对方撤回了一条消息」） | ✅ 可行 | 同一函数的第二个补丁点；群聊提示仍有原生限制 |
| 多开（第二个独立账号） | ✅ 可行 | 复制 App + 新 bundle ID + 去掉沙盒相关 entitlements + 独立数据目录；已实测进程与辅助进程启动 |
| 阻止自动更新 | ⚠️ 视渠道 | App Store 版没有内置更新器；官网版可按 `XAppUpdateManager` 方法定位后屏蔽 |
| 菜单栏控制 / 一键还原 / 备份 | ✅ 可行 | 外部 App，无需注入 |
| 自动回复 | ❌ 不可行（AX） | Qt 界面不暴露聊天内容；只能走屏幕 OCR + 键鼠模拟，脆弱且只能处理当前打开的窗口 |
| 远程控制 | ❌ 不可行（AX） | 同上；需要读取微信消息才能执行指令 |
| 第二次登录免认证 / 保持登录态 | ⚠️ 核心层可研究 | `ilink2` 的 `TdiAutoLoginAsync` 读取 `kTdiKeyAutoauthKey`；官方自动登录优先，客户端 key 持久化不保证服务端接受。见 [`LOGIN-PERSISTENCE.md`](./LOGIN-PERSISTENCE.md) |
| 聊天置底、窗口置顶、多选删除、通知快捷回复、表情包复制 | ❌ 不可行 | 需要修改微信进程内 UI/模型；4.x 没有可用的 ObjC hook 面 |
| 聊天记录导出 / 搜索 | ❌ 不可行 | 本地数据库头部为随机字节，是加密库（社区通常称 SQLCipher），外部读不了 |
| Alfred / Raycast 启动、聚焦 | ✅ 可行 | 只能做「启动/聚焦/打开 URL」；不能可靠搜索联系人或发送消息 |
| 免认证、自动登录、通知快捷回复 | ❌ | 不建议投入 |

**推荐 MVP：防撤回 + 多开 + 菜单栏 + 备份/还原。** 这四项可以做到「用户点一下就能用」，
并且每一项都有明确的失败保护和还原路径。自动回复/远程控制不建议作为第一版承诺。

### 1.1 与社区现有工具的关系

社区已经有可用的 4.x 工具，不必从零造轮子：

- **sunnyyoung/WeChatTweak 2.0**：支持 4.1.5 等构建的防撤回、多开、阻止自动更新；功能范围比旧版
  小助手窄，但核心稳定。
- **zengtianli/WeChatTweak**（AGPL-3.0）：上游的维护分支，补丁库覆盖到 build 270135，支持
  `silent` / `keeptip`、`restore`、`doctor`，并有图形前端 Unrevoke。

本项目的差异/增量：

- 针对本机 **270115 App Store 版**做了实际定位和副本验证（社区配置里不一定有这个构建号）；
- 明确验证了 **4.1.15 的多开副本方案**（新 bundle ID + 去沙盒 + 独立 home）；
- 给出了自动回复/远程控制/免认证登录等功能的 **不可行性结论**，避免用户在不现实的方案上浪费时间；
- 后续计划做更完整的菜单栏/备份/还原/诊断，而不是只做一次性 patch 脚本。

如果用户只需要「防撤回 + 多开」，直接使用社区工具也是合理选择；本项目的价值在于
**针对当前构建的验证、可维护的实现，以及旧功能哪些能做/哪些不能做的清晰边界**。

---

## 2. 为什么旧插件在 4.x 上失效

### 2.1 旧插件的实现方式

旧项目（WeChatPlugin-MacOS）大致依赖：

- 把 `WeChatPlugin.dylib` 注入微信进程；
- 用 Objective-C runtime 找到 `MMMessageMgr`、`MMSessionMgr`、`MMChatSession` 等类；
- swizzle 方法，拦截消息、撤回、窗口、菜单、通知等事件；
- 通过 `insert_dylib` 修改主二进制并重签名。

这套方案在微信 2.x/3.x 上有效，因为当时微信是 Objective-C/AppKit 应用，消息模型和 UI 都是
ObjC 对象。

### 2.2 微信 4.x 的变化

本机 4.1.15 的实际结构：

| 项目 | 观察结果 |
| --- | --- |
| 主程序 | `Contents/MacOS/WeChat` 只有 **184,800 字节**，是启动器 |
| 核心逻辑 | `Contents/Resources/wechat.dylib`，**335 MB** universal（arm64 切片约 169 MB） |
| UI 技术栈 | Qt/C++（二进制里有 `qtmetadata`、Qt Cocoa 集成类），不是 ObjC 业务模型 |
| ObjC 类 | 只有约 80 个类名，主要是 Qt/AppKit 适配、崩溃/录屏/文件 Provider 等；没有 `MMMessageMgr` 这类消息类 |
| 符号 | 业务符号已剥离；`nm` 只有极少数导出符号（`WeChatMain`、`SetWeixinCallbackFunc`） |
| 签名 | App Store 签名，Hardened Runtime（`flags=0x10000(runtime)`），App Sandbox |
| 辅助进程 | `WeChatHelper.app`、`WeChatAppEx.app`、`XPlayer.app`、多个 XPC/Helper |
| 数据 | `~/Library/Containers/com.tencent.xinWeChat`，约 7 GB；`message_0.db`、`session.db` 头部是随机字节，是加密数据库（社区通常称 SQLCipher），不是明文 SQLite |
| 可访问性 | `AXIsProcessTrusted()` 为 true，但主窗口只暴露 3 个 UI 元素（关闭/全屏/最小化）和菜单栏；聊天列表、消息文本、输入框都不可见 |

因此：

- **DYLD 注入 + swizzling 不再有落点**：没有消息类，Hardened Runtime/库验证也会拦截第三方 dylib。
- **不能从外部读消息库**：数据库加密，密钥不在可读位置。
- **不能从 Accessibility 读聊天内容**：Qt 自绘界面没有把聊天内容暴露成 AX 节点。
- 旧插件里「改 UI、读消息、自动回复、免认证」这类功能，在 4.x 上都需要重新做一套
  **二进制逆向 + 协议/内存级修改**，成本和风险远高于旧版。

---

## 3. 可行路径：二进制补丁（不改微信源码，不注入 dylib）

4.x 的防撤回逻辑仍在 `wechat.dylib` 的 C++ 代码里。它不是 ObjC 方法，但可以通过
**固定几何特征的机器码扫描**定位，然后做等长指令替换。

### 3.1 防撤回的机制

参考社区（`fzlzjerry/wechat-antirecall`、`zengtianli/WeChatTweak`，AGPL-3.0）已公开的
`parseRevokeXML` 结构：

```
入口 E
  E + 0x270              cbz  w0, SKIP          ; 如果解析结果为空/失败，跳过撤回处理
  ...
  E + 0x270 + delta      str  x0, [x19,#newmsgid]  ; 记录「要删哪条消息」的 newmsgid
```

两种补丁：

- **silent（静默）**：把 `cbz w0, SKIP` 改成 `b SKIP`，让撤回处理永远跳过。
  - 消息保留，不显示「对方撤回了一条消息」。
  - 这是默认、最稳的变体。
- **keeptip（留提示）**：保留 `cbz`，把 `str x0, [x19,#newmsgid]` 改成 `str xzr, [x19,#newmsgid]`。
  - 消息保留，私聊仍会显示「对方撤回了一条消息」。
  - 群聊仍有原生限制：`newmsgid` 同时决定「删哪条」和「群提示插在哪条下面」；清零后消息能保住，
    但群聊提示可能不出现。这是参考实现也存在的限制。
  - 需要额外的补丁点，且每个版本偏移不同。

### 3.2 本机 4.1.15（270115）的精确补丁点

工具 `tools/locate_revoke.py` 已在本机扫描出唯一命中：

```
微信版本:        4.1.15 (build 270115), App Store, arm64
签名代:          4.1.13+ (269574+)
parseRevokeXML E: 0x4bbaf6c
silent  VA:      0x4bbb1dc   原字节 40 10 00 34  ->  82 00 00 14
keeptip VA:      0x4bbb97c   原字节 60 E6 00 F9  ->  7F E6 00 F9
newmsgid 字段:   [x19,#0x1c8]
```

fat 二进制中的绝对文件偏移：

```
arm64 slice offset = 0xad0c000
silent  file offset = 0xad0c000 + 0x4bbb1dc = 0xf8c71dc
keeptip file offset = 0xad0c000 + 0x4bbb97c = 0xf8c797c
```

反汇编证据：

```
0x4bbb1d8  bl     0x47468f0
0x4bbb1dc  cbz    w0, 0x4bbb3e4        ; 原始
           b      0x4bbb3e4            ; silent 补丁
...
0x4bbb978  bl     0x4a707a4
0x4bbb97c  str    x0, [x19, #0x1c8]    ; 原始 newmsgid
           str    xzr, [x19, #0x1c8]   ; keeptip 补丁
```

> 注意：地址只对 **build 270115** 有效。微信每次更新都会重编译这个函数，地址和 `delta` 都可能变。
> 必须用 `tools/locate_revoke.py` 重新定位，并在写入前校验原始字节。

### 3.3 重签名

修改 `wechat.dylib` 会破坏原签名，必须重签整个 App。4.x 是 App Store + 沙盒 + Hardened Runtime，
直接 `codesign --deep --sign -` 会丢掉 entitlements，在开启 SIP 的 Mac 上直接启动失败。

本机验证过的流程：

1. 逐个代码对象快照 entitlements（app、appex、framework、dylib、helper 等）。
2. 去掉 ad-hoc 签名不能携带的受限权限：`com.apple.developer.*`（App Store 版有
   `com.apple.developer.team-identifier`）。
3. 给每个有 entitlements 的对象注入：
   - `com.apple.security.cs.disable-library-validation`
   - `com.apple.security.cs.allow-unsigned-executable-memory`
4. 由深到浅重签，最后签 App 根；macOS 15+ 使用 `--force-library-entitlements`。
5. `codesign --verify --deep --strict`，失败就再签一次根并复验。
6. 只清理 `com.apple.quarantine`，不要 `xattr -cr` 整个包。

本机结果：**124 个已签名代码对象，23 个带 entitlements，`codesign --verify --deep --strict` 通过。**

> 原则：保留沙盒和原厂权限，只加两个必要的 Hardened Runtime 例外。不要用裸
> `codesign --remove-sign` / `--deep --sign -`。

---

## 4. 多开

### 4.1 旧方案为什么不行

旧插件的多开是 patch 单实例检查，让同一个 bundle ID 的多个进程共存。4.x 的单实例/数据目录/辅助进程
关系更复杂，269602 曾有一个可用的 `multiInstance` 补丁点（返回 1），但 4.1.15 尚未定位到等价的点。

### 4.2 已验证的可行方案：复制 App + 新 bundle ID + 去沙盒

本机测试了三种组合：

| 方案 | 结果 |
| --- | --- |
| 复制 App + 改 bundle ID，保留沙盒 entitlements | ❌ 启动后退出 255；日志显示 crashpad 的 mach service 权限被拒，且仍指向原容器 |
| 复制 App + 改 bundle ID，去掉 `app-sandbox` / `application-identifier` / `application-groups` | ✅ 主进程 + WeChatAppEx + crashpad + 辅助进程全部启动；数据目录独立 |
| 上面方案 + `CFFIXED_USER_HOME=<独立目录>` | ✅ 数据完全落在独立 home；原微信保持运行，互不影响 |

关键点：

- 只改主 App 的 `CFBundleIdentifier` / `CFBundleDisplayName` 就够；辅助 App 的 bundle ID 可以不改，
  它们会从主进程参数拿到新的 `--bundle-id`。
- 必须去掉沙盒相关 entitlements，否则新 bundle ID 与原 app group/application-identifier 不一致，
  crashpad/XPC 会失败。
- 用 `open -n --env CFFIXED_USER_HOME=<instance-home> --env HOME=<instance-home> ...` 启动，
  每个实例一个独立 home，数据不串。
- 代价：每个实例是**独立数据目录**，需要重新登录；不是旧插件那种「同一个微信、第二个窗口」。
  每个副本约占 1.4 GB。

本机验证的副本进程树（摘录）：

```
WeChat-Test.app/Contents/MacOS/WeChat
WeChat-Test.app/Contents/Frameworks/crashpad_handler ...
WeChat-Test.app/Contents/MacOS/WeChatAppEx.app/Contents/MacOS/WeChatAppEx ...
WeChat-Test.app/.../WeChatAppEx Helper ...
```

数据目录（`CFFIXED_USER_HOME`）：

```
<instance-home>/Documents/app_data
<instance-home>/Library/Containers/com.extrawechat.test.wechat/Data/Documents/xwechat_files
```

原微信 `com.tencent.xinWeChat` 仍在运行，未受影响。

### 4.3 单实例补丁（可选，后续）

如果一定要「同一个 bundle ID 多开」，需要继续定位单实例检查。已知线索：

- 运行中的微信持有 `app_data/lock/lock.ini`（`lsof` 可见）；
- `libwxld.dylib` 引用了 `NSRunningApplication`、`isRunning`、`runningApplicationWithProcessIdentifier:`；
- 269602 曾用 `mov w0,#1; ret` patch 一个单实例函数，但 4.1.15 的等价函数尚未定位。

这条路需要更多逆向工作，且两个实例共享数据目录有损坏风险，不建议作为 MVP。复制 App 的方案更稳、
更可控。

---

## 5. 自动回复 / 远程控制：为什么不做

### 5.1 Accessibility 检查结果

本机已授予终端 Accessibility 权限（`AXIsProcessTrusted() == true`），实际读取微信窗口：

```
AXApplication 微信
  AXWindow/AXDialog  (无标题, 187x50)
  AXWindow/AXDialog  微信 (662x808)
    AXButton/AXCloseButton
    AXButton/AXFullScreenButton
    AXButton/AXMinimizeButton
  AXMenuBar ...
```

主窗口内部**没有**聊天列表、消息文本、输入框、按钮等节点。Qt 自绘 UI 没有把业务内容暴露给
Accessibility，因此：

- 无法可靠枚举会话/联系人；
- 无法读取收到的消息；
- 无法定位输入框并输入文字；
- 无法区分「当前打开的是哪个聊天」。

所以旧插件的「自动回复」「远程控制」「通知快捷回复」「表情包复制」不能通过 AX 复刻。

### 5.2 唯一的外部替代：屏幕 OCR + 键鼠模拟

理论上可以：

1. 用 ScreenCaptureKit 截取微信窗口；
2. 用 Vision OCR 识别聊天区域文字；
3. 用 CGEvent 点击输入框、粘贴回复、回车发送。

但限制很大：

- 只能处理**当前可见**的聊天窗口，不能后台监听所有消息；
- 依赖窗口位置、分辨率、主题、字体、缩放；
- 无法可靠区分消息气泡的发送者/时间/引用；
- 需要「屏幕录制 + 辅助功能」权限；
- 微信 UI 更新就可能失效；
- 回复延迟高，容易误发。

如果确实要做，建议作为**独立的实验模式**，默认关闭，并明确提示风险。第一版不建议承诺。

### 5.3 二次免验证 / 保持登录状态

这里要区分三件事：

1. **官方自动登录**：手机确认页勾选「自动登录 / 在本机自动登录」后，本机启动无需手机确认。
   这是微信官方支持的方式，优先使用。
2. **锁定状态退出后的二次确认**：微信会主动失效本机登录态，要求手机确认。这是安全策略，
   客户端 patch 不保证能绕过服务端校验。
3. **旧插件的「免认证登录」**：3.x 通过 `AccountService` 的 `GetLastLoginAutoAuthKey` /
   `canAutoAuth` / `AutoAuth` 重放登录态；4.x 对应逻辑在 `ilink2.framework` 的
   `TdiAutoLoginAsync`，它读取 `kTdiKeyAutoauthKey`，key 为空就打印
   `autoauth_key is empty, require manual login!` 并返回 `-14`。

所以「内核层」大概率指 `ilink2` 的 C++ 认证核心，不是 macOS kext。技术上可以在这一层做
**登录态保持（key 持久化 + 重放）**，但需要捕获/安全保存/注入 autoauth key，并且要处理服务端
拒绝的情况；它不是改一个跳转就能稳定免验证。

详见 [`LOGIN-PERSISTENCE.md`](./LOGIN-PERSISTENCE.md)。**不作为 MVP 承诺。**

---

## 6. 其他旧功能对照

| 旧功能 | 4.x 可行性 | 说明 |
| --- | :---: | --- |
| 消息防撤回 | ✅ | 本文核心方案 |
| 微信多开 | ✅ | 复制 App + 新 bundle ID + 独立 home |
| 阻止自动更新 | ⚠️ | App Store 版由 App Store 更新；官网版可按 ObjC `XAppUpdateManager` 方法 patch |
| 自动回复 | ❌ | AX 无内容；OCR 方案仅实验 |
| 远程控制 | ❌ | 同上，且执行 shell 有安全风险 |
| 第二次登录免认证 / 保持登录态 | ⚠️ | 核心层可研究，风险高；官方自动登录优先 |
| 聊天置底 | ❌ | 需要进程内 UI/模型修改 |
| 窗口置顶 | ❌ | 需要改 NSWindow level；外部只能激活/聚焦 |
| 会话多选删除 | ❌ | 需要 UI 内部接口 |
| 一键已读 / 清空会话 | ❌ | 需要 UI 内部接口；快捷键只能处理当前会话 |
| 通知中心快捷回复 | ❌ | 不能给别的 App 的通知加 action |
| 表情包复制/存储 | ❌ | 无法读取消息内容 |
| Alfred / Raycast | ⚠️ | 只能启动/聚焦/打开 URL；不能可靠搜索联系人或发消息 |
| 聊天记录导出/搜索 | ❌ | 加密数据库，外部无密钥 |
| 菜单栏 / 一键还原 / 备份 | ✅ | 外部 App 可做 |
| 检查更新 / 禁用更新 | ⚠️ | 官网版可做；App Store 版交给 App Store |

---

## 7. 本机验证记录（副本测试）

完整命令和日志见 [`TEST-REPORT.md`](./TEST-REPORT.md)。摘要：

1. **只读定位**：`tools/locate_revoke.py` 在 `/Applications/WeChat.app` 上唯一命中
   `4.1.13+` 代签名，地址与本文一致。
2. **副本补丁 + 重签**：`tools/patch_copy.py` 复制 `/Applications/WeChat.app` 到临时目录，
   patch silent 点，重签 124 个代码对象，`codesign --verify --deep --strict` 通过。
3. **副本启动**：
   - 保留原 bundle ID + 沙盒的副本：在原微信运行时启动，退出 255；日志里没有 AMFI/签名错误，
     已加载副本内的 `wechat.dylib`（补丁已写入），并访问原容器。**这更像单实例保护，而不是签名被拒**；
     需要退出原微信后再确认能否正常进入登录/主界面。
   - 新 bundle ID + 去沙盒的副本：主进程和辅助进程启动成功，使用独立数据目录，原微信不受影响。
4. **未完成**：真实「对方撤回一条消息」的端到端测试（需要登录第二个账号或临时退出主微信），
   以及 keeptip 变体的私聊/群聊实测。

**结论：技术路径成立，但正式安装到 `/Applications/WeChat.app` 前，必须再做一次
「退出微信 → 打补丁 → 启动 → 真实撤回 → 还原」的验收。**

---

## 8. 建议的工程实现

### Phase 0（已完成）

- 只读定位器 `tools/locate_revoke.py`；
- 副本补丁/重签 PoC `tools/patch_copy.py`；
- 本报告 + 测试报告 + 补丁点文档。

### Phase 1：CLI（建议下一步）

一个 Swift 命令行工具 `extrawechat`，不依赖 Python：

```
extrawechat doctor                 # 版本/构建/渠道/架构/SIP/签名/补丁状态/写入权限
extrawechat patch --variant silent # 备份 -> 补丁 -> 重签 -> 验证
extrawechat patch --variant keeptip
extrawechat restore                # 写回原始字节 -> 重签 -> 验证
extrawechat clone --name 2         # 复制 App -> 新 bundle ID -> 去沙盒 -> 重签
extrawechat launch --instance 2    # 用独立 CFFIXED_USER_HOME 启动
extrawechat status --json          # 给 GUI 用
```

安全要求：

- 微信运行时拒绝 patch/restore；
- patch 前自动备份 `wechat.dylib` 和 entitlements；
- 每个补丁点做原始字节校验，不匹配就拒绝；
- 支持逐字节还原；
- App Store 版自动跳过更新器 patch；
- 写入 `/Applications` 需要「App 管理」权限时给出明确提示。

### Phase 2：菜单栏 App

- 菜单栏常驻，显示「已保护 / 未保护 / 需要重打」；
- 一键开启/关闭防撤回（silent / keeptip）；
- 一键启动第二实例；
- 一键还原；
- 显示微信版本/build，更新后提示重新打补丁；
- 日志与诊断导出。

### Phase 3：可选

- 官网版屏蔽自动更新（按 `XAppUpdateManager` 方法名定位）；
- 新版本自动定位（扩展 `SIGNATURES` 表）；
- 更新检查、备份管理；
- 实验性 OCR 自动回复（默认关闭，独立权限和风险提示）。

### 不做

- 免认证登录；
- 聊天记录解密/导出；
- 通知快捷回复；
- 进程内 UI 修改；
- 任何需要绕过腾讯账号安全的风控功能。

---

## 9. 风险与注意事项

1. **修改微信违反腾讯用户协议**，存在账号风险；请只在本人设备、本人账号上使用。
2. 修改后 App Store 签名失效，微信更新会整包替换并清除补丁；每次更新后需重新打。
3. App Store 版的自动更新由 App Store 控制，无法在微信内部关闭；建议在 App Store 设置里关闭自动更新，
   或更新后重新运行工具。
4. macOS 的 App Management/TCC 可能阻止写入 `/Applications`；需要在「系统设置 → 隐私与安全性 →
   App 管理」中给终端/工具授权。
5. 不要分发打补丁后的 `WeChat.app`；只分发工具和脚本，由用户在自己的副本上操作。
6. 不要在微信运行时 patch/restore；辅助进程可能残留，先完全退出。
7. 备份聊天记录和原始 `wechat.dylib`。虽然本方案只改 4~8 个字节，但签名/沙盒操作仍有风险。
8. 本报告中的地址只对 build 270115 有效；其他版本必须重新定位并校验原始字节。

---

## 10. 需要用户确认的决策

1. MVP 是否按「防撤回 + 多开 + 菜单栏 + 备份/还原」推进？
2. 默认变体选 **silent**（不显示撤回提示）还是 **keeptip**（私聊保留提示）？
3. 多开是否接受「复制 App、独立数据目录、需要重新登录」？还是必须尝试同数据目录的单实例补丁？
4. 是否接受修改 `/Applications/WeChat.app` 并重签名（保留 entitlements、支持一键还原）？
5. 是否要投入「登录态保持」的核心层研究（高风险、默认关闭、不保证服务端接受）？
6. 验收方式：能否在方便时退出微信，配合做一次「打补丁 → 启动 → 真实撤回 → 还原」测试？

---

## 附录 A：参考与致谢

- 旧项目：[TKkk-iOSer/WeChatPlugin-MacOS](https://github.com/TKkk-iOSer/WeChatPlugin-MacOS)（MIT）
- 4.x 补丁点与重签思路：
  - [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall)
  - [zengtianli/WeChatTweak](https://github.com/zengtianli/WeChatTweak)（AGPL-3.0）
  - [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)（AGPL-3.0）
- 本项目的几何签名表、补丁点数据和重签流程参考了上述公开资料；本项目代码按 AGPL-3.0 发布。

## 附录 B：关键命令

```bash
# 只读定位（不会改任何文件）
python3 tools/locate_revoke.py --app /Applications/WeChat.app

# 在副本上打 silent 补丁 + 重签 + 验证
python3 tools/patch_copy.py \
  --app /Applications/WeChat.app \
  --output ~/Applications/WeChat-Test.app \
  --variant silent

# 复制一个独立多开实例（不登录、独立数据目录）
python3 tools/patch_copy.py \
  --app /Applications/WeChat.app \
  --output ~/Applications/WeChat-2.app \
  --variant none --clone 2

# 验证签名
codesign --verify --deep --strict --verbose=2 ~/Applications/WeChat-Test.app
```
