# 登录态保持（实验）

> **高风险功能，默认关闭。** 它保存的是微信的 `autoauth` 登录凭据（Base64），
> 只应在本机、本人账号上使用。不要把 `login_keys.tsv` 发给任何人，也不要把打补丁后的
> 微信 App 分发给别人。

## 它做什么

微信 4.x 的登录核心在 `ilink2.framework`：

- `TdiAutoLoginAsync` 从 `TdiContext` 的 `ini_file` 读取 `kTdiKeyAutoauthKey`；
- 如果 key 为空，打印 `autoauth_key is empty, require manual login!` 并返回 `-14`，
  然后回退到手机确认；
- 如果 key 存在，调用 `SendAutoAuthRequestAsync` 发 `autoauth` 请求。

本目录的 `login_persist.mm` 编译成一个小 dylib，通过 `DYLD_INSERT_LIBRARIES` 注入微信，
hook `owl::v9::ini_file::get/set`：

- 当微信写入/读取到 `kTdiKeyAutoauthKey` / `kTdiKeyAutoauthEncKey` 且值非空时，保存到：
  `Library/Application Support/ExtraWeChat/login_keys.tsv`（0600）；
- 当微信读取到的值为空、而本地有保存值时，返回保存值，让 `TdiAutoLoginAsync` 继续走
  autoauth；
- 如果服务端拒绝，微信仍会回退到官方手机确认流程——**不保证一定免验证**。

## 构建

```bash
cd tools/login_persist
./build.sh          # 默认 arm64；需要 Intel 时 ARCH=x86_64 ./build.sh
```

产物：`tools/login_persist/build/libExtraWeChatLogin.dylib`

## 在副本上测试（推荐）

1. 先做一个允许 `DYLD_INSERT_LIBRARIES` 的副本：

```bash
python3 tools/patch_copy.py \
  --app /Applications/WeChat.app \
  --output ~/Applications/WeChat-LoginTest.app \
  --variant none \
  --allow-dyld-env \
  --force
```

> 主 App 副本会保留原 bundle ID / 沙盒，因此会使用原微信的容器；
> 启动前必须完全退出原微信。不要在原微信运行时启动这个副本。

2. 退出微信（⌘Q，确认 helper 也退出）：

```bash
pgrep -fl '/WeChat.app/Contents/MacOS'   # 应该没有输出
```

3. 启动副本并观察：

```bash
EXTRAWECHAT_LOGIN_DEBUG=1 tools/login_persist/run.sh ~/Applications/WeChat-LoginTest.app
```

4. 首次登录按正常流程扫码/手机确认。登录后查看日志：

```bash
cat ~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application\ Support/ExtraWeChat/login_persist.log
cat ~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application\ Support/ExtraWeChat/login_keys.tsv
```

预期：

- 登录/启动过程中出现 `[capture] kTdiKeyAutoauthKey length=...`；
- 下次启动如果微信自己把 key 读成空，会出现 `[inject] kTdiKeyAutoauthKey length=...`；
- 如果服务端拒绝，微信仍然显示手机确认，这是预期行为。

5. 想关闭/清除：

```bash
rm ~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application\ Support/ExtraWeChat/login_keys.tsv
# 或者启动时：
EXTRAWECHAT_LOGIN_PERSIST=0 tools/login_persist/run.sh ...
```

## 日志/存储位置

- 主 App（沙盒）：
  `~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/ExtraWeChat/`
- 多开副本（`CFFIXED_USER_HOME`）：
  `<instance-home>/Library/Application Support/ExtraWeChat/`
- 文件权限：目录 0700、文件 0600。
- 内容：`key_name<TAB>base64_value`。**这是登录凭据，不要外传。**

## 为什么不是 kext

macOS 26/27 对 kext 强限制，需要关闭 SIP/降低安全性；微信登录逻辑在用户态
`ilink2.framework`，kext 无法直接 hook C++ 函数。真正的「核心层」是 `ilink2`，
本方案就是在这一层做 key 持久化，不需要内核扩展。

## 已知限制

1. 服务端可能因为「锁定状态退出」或风控拒绝保存的 key；此时只能回退手机确认。
2. 微信更新后 `owl`/`ilink2` 的符号或 ABI 可能变化；需要重新验证 hook。
3. 保存 key 会降低账号安全性；请确保机器磁盘加密、Keychain/文件权限正确。
4. 当前原型用 0600 文件保存 key；正式版本应迁移到 Keychain。
5. 不要在多账号之间混用同一个 `login_keys.tsv`；当前实现是“最后写入的 key 生效”。
6. 本功能不修改 `/Applications/WeChat.app`，只作用于显式加 `--allow-dyld-env` 的副本；
   正式安装器需要单独设计开关和一键清除。

## 文件

- `login_persist.mm`：dylib 源码（fishhook + Foundation）
- `vendor/fishhook.*`：Facebook fishhook（BSD，见文件头）
- `build.sh` / `run.sh`
- `host.py` / `agent.js`：Frida 诊断原型（备用，不参与 dylib 方案）

## 安全边界

- 只用于**你自己的**微信账号和机器；
- 不实现、不提供任何服务端协议绕过；
- 不收集、不上传 key；
- 发现异常/被要求二次验证时，删除 `login_keys.tsv` 并回到官方登录。
