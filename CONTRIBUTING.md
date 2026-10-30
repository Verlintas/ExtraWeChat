# 贡献指南

感谢你愿意改进 ExtraWeChat。这个项目的目标是做**本机、可回退的微信客户端增强**，不是机器人或群发工具。

## 可以贡献什么

- 新的微信构建号适配（`tools/revoke_profiles.json` + 测试）
- 防撤回边缘情况、错误信息和回滚逻辑
- 窗口隐私、主题、开发者页等本地功能
- 文档、兼容性表、网站和截图
- 不涉及自动发消息、群发、自动领红包或服务端协议绕过的改进

## 开发环境

- Apple Silicon Mac
- macOS 13+
- Xcode Command Line Tools（提供 Swift、clang、codesign、`/usr/bin/python3`）
- 可选：Pillow（重新生成图标/网站截图时使用）

## 本地构建

```bash
./scripts/build_app.sh
./scripts/build_pkg.sh
open build/ExtraWeChat.app
```

产物在 `build/`：

- `ExtraWeChat.app`
- `ExtraWeChat-<version>-arm64.zip`
- `ExtraWeChat-<version>-arm64.pkg`

## 测试

```bash
python3 -m unittest discover -s tests -v
python3 tools/locate_revoke.py --app /Applications/WeChat.app
python3 tools/locate_revoke.py --app /Applications/WeChat.app --force-scan
```

修改补丁逻辑时，至少要在独立 `wechat.dylib` 副本上完成：

```text
pristine → silent → keeptip → pristine
```

涉及完整 App 时，再做一个 `~/Applications` 副本并验证 `codesign --verify --deep --strict`。

## 新增微信构建

1. 打开「开发者」页复制报告，或运行定位器；
2. 确认 `CFBundleVersion`、渠道（App Store / 官网）和架构；
3. 如果 `Match: profile`，说明已收录；
4. 如果 `Match: signature`，可以把地址加入 `tools/revoke_profiles.json`；
5. 如果两者都没有，按 `docs/PATCH-270115.md` 第 7 节人工定位；
6. 更新 `tests/test_profiles.py`；
7. 在补丁副本上做真实撤回测试，再提交 PR。

不要把完整 `wechat.dylib`、聊天记录或 `login_keys.tsv` 上传到 issue/PR。

## 代码风格

- 所有源文件保留 SPDX 头：
  ```text
  SPDX-FileCopyrightText: 2026 Verlintas
  SPDX-License-Identifier: AGPL-3.0-only
  ```
- Swift 使用 4 空格；Python 保持现有风格；
- 错误信息要可操作，不要只抛 traceback；
- 写入前必须校验原始字节，失败必须拒绝或回滚；
- 不引入遥测、账号系统或上传聊天内容。

## 网站

官网源码在 `site/`。本地预览：

```bash
python3 -m http.server 8000 -d site
```

部署：

```bash
./scripts/deploy_site.sh
```

站点固定微信绿，不再提供颜色切换。

## 提交 PR

- 说明改动和验证方式；
- 附上 macOS / 微信构建号 / 渠道；
- 如果改了补丁表，附上定位器输出；
- 确认没有提交 key、聊天内容或完整微信二进制；
- 同意以 AGPL-3.0-only 发布贡献。
