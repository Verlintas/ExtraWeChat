# 路线图

> 前置条件：用户确认 [`FEASIBILITY.md`](FEASIBILITY.md) 第 10 节的决策。
> 在确认前，不修改 `/Applications/WeChat.app`。

## Phase 0 — 可行性验证（已完成）

- [x] 识别 4.x 架构（Qt/C++、`wechat.dylib`、沙盒、Hardened Runtime）
- [x] 只读定位 270115 防撤回补丁点
- [x] 副本 silent 补丁 + 重签 + 签名验证
- [x] 副本启动测试（原 bundle ID / 新 bundle ID）
- [x] 多开副本启动测试
- [x] Accessibility 能力评估
- [x] 可行性报告 / 测试报告 / 补丁点文档

## Phase 1 — 正式 CLI（已完成 Python 版）

当前用 Python 实现，GUI 通过 `/usr/bin/python3` 调用。自包含 Swift CLI 仍可后续替换。

### 命令

```text
python3 tools/install.py status --json
python3 tools/install.py install --variant silent|keeptip
python3 tools/install.py restore
python3 tools/patch_copy.py --clone NAME
python3 tools/locate_revoke.py
```

### 必须实现

- [ ] 版本/构建号/渠道/架构检测
- [ ] 运行中检测：patch/restore 前要求微信完全退出（含 helper）
- [ ] 备份：`wechat.dylib`、entitlements 快照、Info.plist
- [ ] 补丁点定位：内置 270115 地址 + 几何签名自动定位
- [ ] 原始字节校验；不匹配拒绝写入
- [ ] 逐字节还原
- [ ] 逐对象 entitlements 快照/恢复
- [ ] 去掉受限 `com.apple.developer.*`
- [ ] 注入 `disable-library-validation` / `allow-unsigned-executable-memory`
- [ ] `codesign --verify --deep --strict` 后置检查
- [ ] App Store 版跳过更新器 patch；官网版按 `XAppUpdateManager` 定位
- [ ] 写入 `/Applications` 的 App Management/TCC 诊断
- [ ] 日志与 `--json` 输出

### 验收

- [ ] 在副本上：patch silent → 启动 → 真实撤回 → 消息保留
- [ ] 在副本上：patch keeptip → 私聊消息保留 + 提示；群聊记录实际表现
- [ ] restore → 字节与原始包一致 → 签名通过 → 微信启动
- [ ] 重复 patch 幂等
- [ ] 错误构建号/错误字节拒绝写入
- [ ] 主微信退出后，patch 主 App 并正常启动

## Phase 2 — GUI App（已完成第一版）

- [x] SwiftUI 窗口 + 菜单栏
- [x] 状态：已保护 / 未保护 / 不支持
- [x] 一键安装/还原防撤回（silent/keeptip）
- [x] 多开实例创建/启动/删除
- [x] 登录态保持开关 / 带 dylib 启动 / 清除 key
- [x] 诊断导出（版本、签名、entitlements、补丁状态、路径）
- [ ] 真实主 App 验收（需要退出微信）
- [ ] App 管理权限引导按钮
- [ ] 公证/正式签名（当前 ad-hoc）
- [ ] 自包含 Swift 引擎（去掉 Python 运行时依赖）

### 验收

- [x] GUI 能读取微信版本/构建/补丁状态
- [x] GUI 能构建、打包、生成 Release zip
- [ ] 非开发者用户可完成：安装 → 开启 → 重启微信 → 验证 → 还原
- [ ] 登录态保持完整验收

## Phase 3 — 可选增强

- [ ] 官网版屏蔽自动更新
- [ ] 新构建号自动定位（扩展几何签名表）
- [ ] 备份管理/回滚多个版本
- [ ] 更新检查
- [ ] 更完整的 keeptip 群聊提示方案（需要动态定位下游删除调用，独立工程）
- [ ] 同 bundle ID 多开（定位单实例检查，风险较高）
- [x] 登录态保持原型（`ilink2` 核心层 dylib + 0600 key store；hook 安装已验证）
- [ ] 真实账号 key 捕获 / 注入 / 服务端接受验证
- [ ] 迁移 Keychain + 多账号隔离 + 默认关闭开关

## Phase 4 — 实验性（默认关闭）

- [ ] ScreenCaptureKit + Vision OCR 自动回复
- [ ] 远程控制（仅允许白名单命令，显式确认）
- [ ] 聊天窗口悬浮/置顶（外部窗口 overlay，不修改微信）

> OCR/远程控制只能处理当前可见窗口，无法后台读取全部消息；需要屏幕录制/辅助功能权限；
> 微信 UI 更新即可能失效。不作为核心承诺。

## 不做

- 绕过服务端二次验证的承诺（只做本机登录态保持的实验研究，不保证服务端接受）
- macOS kext / 内核扩展方案
- 聊天记录解密/导出
- 通知中心快捷回复
- 进程内 UI 修改
- 绕过腾讯账号安全/风控
- 分发打补丁后的微信 App

## 里程碑建议

| 里程碑 | 内容 | 预计 |
| --- | --- | --- |
| M1 | Swift CLI：doctor/patch/restore | 1–2 天 |
| M2 | 主 App 验收 + 备份/还原 | 0.5 天 |
| M3 | clone/launch 多开 | 0.5–1 天 |
| M4 | 菜单栏 App | 2–3 天 |
| M5 | 官网版更新屏蔽 + 自动定位 | 1–2 天 |
| M6 | OCR 自动回复（可选） | 3–5 天，风险高 |
