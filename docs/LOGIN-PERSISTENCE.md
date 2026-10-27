# 二次免验证 / 保持登录状态：可行性分析

> 结论先说：**"内核层"大概率指微信的核心 C++ 登录层（`ilink2.framework` / TdiAuthManager），
> 不是 macOS 内核扩展（kext）。** 4.1.15 的登录核心里确实有一个 `TdiAutoLoginAsync`，
> 它从 `ini_file` 读取 `kTdiKeyAutoauthKey`；key 为空就打印
> `autoauth_key is empty, require manual login!` 并返回 `-14`，然后回退到手机确认。
>
> 这条路技术上存在，但**不是改一个跳转就能稳定免验证**：需要保存/恢复 autoauth key，
> 而且服务端仍可能因为「锁定状态退出」拒绝自动登录。官方「自动登录」仍然是首选。

---

## 1. 先区分三种「免验证」

| 说法 | 实际含义 | 建议 |
| --- | --- | --- |
| **官方自动登录** | 手机确认登录时勾选「自动登录 / 在本机自动登录」，之后本机启动无需手机确认 | ✅ 首选，微信官方支持 |
| **锁定状态退出后的二次确认** | 上次在锁屏/锁定状态下退出微信，本次登录强制手机确认 | ⚠️ 这是安全策略，客户端 patch 不一定能绕过服务端校验 |
| **旧插件的「免认证登录」** | 3.x 时代用 `AccountService` 的 `GetLastLoginAutoAuthKey` / `canAutoAuth` / `AutoAuth` 自动重放登录态 | 4.x 对应逻辑搬到了 `ilink2` 的 `TdiAutoLoginAsync` |

微信 4.1.15 的界面字符串已经写得很清楚：

```
开启后，在本机登录微信将无需手机确认。
关闭后，下次登录需要手机确认
仅支持在手机上开启此功能。
上次在锁定状态下退出微信，本次登录需要通过手机确认。
```

所以：

1. 如果只是「每次启动都要手机确认」，先检查手机确认页有没有勾选「自动登录」。
2. 如果提示「上次在锁定状态下退出」，这是微信主动失效了本机登录态，属于安全策略；
   客户端强推 autoauth 也可能被服务端拒绝。

---

## 2. 4.x 的登录核心在哪里

旧版插件 hook 的是 `AccountService`（Objective-C）。4.x 里这套已经不存在，登录逻辑在：

- `Contents/Resources/ilink2.framework/Versions/A/ilink2`
- 主程序通过 `wechat.dylib` 链接 `ilink2`；
- `ilink2` 里保留了 C++ 符号和字符串，比 `wechat.dylib` 好分析得多。

关键符号/字符串：

```
TdiAutoLoginAsync
TdiAuthManager::SendAutoAuthRequestAsync
TdiAuthManager::SendManualAuthRequestAsync
AutoAuthRequest / AutoAuthResponse
/ilink/ilinkapp/sys/ilinkapp_autoauth
autoauth_key is empty, require manual login!
autoauth_key = %_
autoauth_enc_key = %_
kTdiKeyAutoauthKey
kTdiKeyAutoauthEncKey
```

`wechat.dylib` 侧还有：

```
mmkv_key_auto_login_flag
mmkv_key_auto_auth_key
mmkv_key_old_wechat_auto_login_loaded
pc_auto_login
GetAutoLoginInfo
ClearAutoLoginInfo
auto_login_switch
Auto Login
```

这说明 4.x 的登录态大致分两层：

- **UI/登录服务层**（`wechat.dylib`）：MMKV 标志、自动登录开关、登录界面；
- **认证核心层**（`ilink2`）：`TdiAutoLoginAsync` 读取 autoauth key，发 `autoauth` 请求。

---

## 3. `TdiAutoLoginAsync` 的实际流程（4.1.15 arm64）

在 `ilink2` 的 arm64 切片里：

```
TdiAutoLoginAsync 入口：0x2000
字符串 "autoauth_key is empty..." 的引用：0x2160
空 key 分支：0x2108 -> 0x2180（错误码 -14）
```

伪代码：

```c
TdiAutoLoginAsync(ctx, ...) {
    key = ini_file_get(ctx->ini_file, "kTdiKeyAutoauthKey", "");
    key = base64_decode(key);
    if (key.empty()) {
        log("autoauth_key is empty, require manual login!");
        response.error = -14;
        return response;              // 回退到手动登录/手机确认
    }
    SendAutoAuthRequestAsync(ctx, key, ...);  // /ilink/ilinkapp/sys/ilinkapp_autoauth
}
```

`TdiAutoLoginAsync` 只有一个调用点（arm64 `0x5e154`），调用者从 `TdiContext` 里取
`ini_file`（`ctx+0x10`）并处理返回值。

补充：`kTdiKeyAutoauthKey` 是通过 `owl::v9::ini_file::get` 读的；`ini_file` 可能来自
`TdiContext` 的内存配置，不一定是磁盘上可直接看到的明文 INI。当前用户的
`app_data/ilink/netbridge/*.ini` 是 0 字节，`login_config` 16K 全零，
`login_configv2` 128K 是加密数据，所以**不能靠直接改文件来稳定恢复 key**。

---

## 4. 为什么「改一个跳转」不靠谱

最容易想到的是把空 key 检查跳过去：

```
if (key.empty()) -> 强制不跳，继续走 SendAutoAuthRequestAsync
```

但这样只是拿一个**空 key**去请求服务端，服务端不会认。必须解决：

1. **key 从哪里来**：成功登录后捕获 `autoauth_key`（以及 `autoauth_enc_key`），安全保存；
2. **key 何时失效**：锁定状态退出、会话超时、服务端风控都可能让 key 失效；
3. **服务端是否接受**：即使客户端重放，服务端仍可能要求手机确认；
4. **存储安全**：把 key 存到本地等于保存一份登录凭据，必须放 Keychain，不能明文落盘。

所以正确方向是「**核心层 key 持久化 + 重放**」，不是「绕过验证」：

- hook `TdiAutoLoginAsync` / `SendAutoAuthRequestAsync`，在成功登录时记录 key（只记录长度/哈希用于诊断，
  实际保存用 Keychain）；
- 下次启动时，在 `TdiAutoLoginAsync` 读取 key 之前把保存的 key 写回 `TdiContext` 的 `ini_file`；
- 处理 `AutoAuthResponse` 的错误码：如果服务端要求手机确认，仍然回退到官方流程，不要死循环；
- 明确开关，默认关闭，失败自动还原。

这属于「登录态持久化」，风险高于防撤回：
- 违反腾讯用户协议，可能导致账号被要求二次验证/限制；
- key 是敏感凭据，泄露等于账号风险；
- 微信更新后 `ilink2` 地址/结构变化，需要重新适配。

---

## 5. 「内核层」到底是不是 macOS kext？

大概率不是。原因：

1. macOS 26/27 对 kext 默认强限制，需要关闭 SIP、降低安全性；普通用户不会为了一个微信插件这么做。
2. 微信是用户态 App，登录逻辑在 `ilink2` 的 C++ 代码里；kext 无法直接 hook C++ 函数，
   只能拦截系统调用/文件/TLS，既复杂又脆弱。
3. 真正稳定的是 **用户态的 core hook**（Frida/LLDB/二进制 patch），也就是 `ilink2` 这一层。
   社区里说的「底层/内核层」通常指 App 的核心逻辑层，不是操作系统内核。

如果确实有人做了 kext，那更可能是：
- 网络层拦截（TLS 代理/重放）——需要处理证书 pinning，风险高；
- 文件层保护（阻止登录态文件被清）——但 key 是加密的，单保护文件不一定有用；
- 进程/签名层 hook——和登录态无关。

不建议走 kext 路线。

---

## 6. 建议的验证顺序

### 第一步：官方自动登录（零风险）

1. 在手机上打开微信的登录确认页；
2. 勾选「自动登录 / 在本机自动登录」；
3. 正常退出微信，再启动，确认是否还需要手机确认；
4. 如果仍然提示「锁定状态退出」，说明是安全策略，不是没开自动登录。

### 第二步：只读诊断（低风险）

在副本上 re-sign `get-task-allow`，用 Frida/LLDB attach：

- 在 `TdiAutoLoginAsync` 入口打印 `ctx->ini_file` 的 key 长度（不打印 key 本身）；
- 观察正常退出 vs 锁定状态退出后，key 是否为空；
- 观察 `AutoAuthResponse` 的错误码。

这一步可以确认「到底是 key 没保存，还是服务端拒绝」，再决定是否值得做持久化。

### 第三步：核心层 key 持久化（高风险，需单独确认）

如果第二步证明 key 存在但被清掉，才考虑：

- 在成功登录时捕获 key；
- 存 Keychain；
- 下次启动在 `TdiAutoLoginAsync` 之前注入；
- 服务端拒绝时回退官方确认；
- 提供一键关闭/清除保存的 key。

**不建议**把它做成默认功能，也不建议在没有真机验证的情况下承诺「免二次验证」。

---

## 7. 对项目的建议

- MVP 仍然保持「防撤回 + 多开 + 菜单栏 + 备份/还原」，不把免验证作为核心卖点；
- 如果用户明确需要，作为 **Phase 3 实验功能**，默认关闭，单独风险提示；
- 不在文档/UI 里写「绕过安全验证」，而是写「本机登录态保持（实验）」；
- 不实现 kext；不做服务端协议逆向；不保存明文 key；
- 任何测试都在副本/独立数据目录进行，先备份聊天数据。

---

## 8. 关键结论

1. **"内核层" = `ilink2` 核心层**，不是 macOS kext；技术上可 hook，但比防撤回复杂得多。
2. **官方自动登录优先**；「锁定状态退出」是服务端安全策略，客户端 patch 不保证能绕过。
3. **单独改空 key 分支没有意义**；必须解决 key 的捕获、保存、注入和服务端接受问题。
4. 可以做「登录态保持」的实验功能，但应默认关闭、明确风险，并且不能承诺稳定免验证。


---

## 9. 原型实现（已完成，待真实账号验证）

本仓库已经包含一个实验性 dylib：

- `tools/login_persist/login_persist.mm`
  - 用 fishhook hook `owl::v9::ini_file::get/set`；
  - 捕获非空的 `kTdiKeyAutoauthKey` / `kTdiKeyAutoauthEncKey`；
  - 当微信读到的值为空时，返回本地保存的值；
  - 服务端拒绝时仍回退微信官方手机确认。
- `tools/login_persist/build.sh`：编译 + ad-hoc 签名；
- `tools/login_persist/run.sh`：检查微信未运行，设置 `DYLD_INSERT_LIBRARIES` 后启动副本；
- `tools/login_persist/README.md`：完整使用说明和风险提示。

存储位置（主 App 沙盒容器）：

```
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/ExtraWeChat/
  login_keys.tsv      # 0600，key_name<TAB>base64_value
  login_persist.log   # 诊断日志，只记录长度/动作，不记录 key 原文
```

主 App / 副本必须重新签名并带：

- `com.apple.security.cs.allow-dyld-environment-variables`
- `com.apple.security.cs.disable-library-validation`

可以用 `tools/patch_copy.py --allow-dyld-env` 在副本上完成；正式安装器需要把这两个权限
纳入 patch/restore 流程，并提供单独开关。

### 当前状态

- [x] dylib 编译、签名、注入副本成功；
- [x] hook 在 `ilink2` 加载后安装成功（fishhook 返回原函数指针）；
- [ ] 真实账号的 key 捕获（需要退出主微信并用已登录副本启动）；
- [ ] 空 key 时注入 + 服务端接受验证；
- [ ] 锁定状态退出后的恢复验证；
- [ ] 迁移到 Keychain、多账号隔离、正式 UI 开关。

### 测试命令（需要退出主微信）

```bash
# 1. 构建 dylib
tools/login_persist/build.sh

# 2. 做一个允许 DYLD 注入的副本（主 App 副本，保留原 bundle ID/沙盒）
python3 tools/patch_copy.py \
  --app /Applications/WeChat.app \
  --output ~/Applications/WeChat-LoginTest.app \
  --variant none --allow-dyld-env --force

# 3. 完全退出微信后启动
EXTRAWECHAT_LOGIN_DEBUG=1 tools/login_persist/run.sh ~/Applications/WeChat-LoginTest.app

# 4. 查看日志（不要把 key 原文发出来）
tail -50 ~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application\ Support/ExtraWeChat/login_persist.log
```

## 10. 结论（更新）

「内核层」= `ilink2` 核心层；本仓库已经做出可运行的 dylib 原型。
但**是否真的能免二次验证取决于服务端是否接受保存的 key**，必须用真实账号做
「正常登录 → 退出 → 再启动 → 锁定状态退出 → 再启动」的完整验收。
在验收通过前，不要把它当成稳定功能，也不要把 key 文件外传。
