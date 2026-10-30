# NOTICE / 第三方致谢

本项目（ExtraWeChat）的代码以 **AGPL-3.0-only** 发布。
Copyright (C) 2026 Verlintas and ExtraWeChat contributors.

所有项目源文件均带有 SPDX 版权与许可标识：

```text
SPDX-FileCopyrightText: 2026 Verlintas
SPDX-License-Identifier: AGPL-3.0-only
```

`tools/revoke_profiles.json` 中的构建地址数据来自 zengtianli/WeChatTweak 的公开
AGPL-3.0 配置，详见下方致谢。第三方文件保留其原始版权头。

以下项目提供了 4.x 补丁点、几何签名或重签思路的
公开资料，在此致谢：

## fzlzjerry/wechat-antirecall

- 提供 WeChat 4.x `parseRevokeXML` 的补丁思路、`revoke-tip`（keeptip）模式、更新器方法定位方法。
- 本项目 `docs/PATCH-270115.md` 中的几何参数和补丁机制参考了该项目。

## zengtianli/WeChatTweak (AGPL-3.0)

- 提供 4.x 的多代几何签名表、`locate_revoke.py` / `locate_update.py` 的定位思路、
  App Store 版 entitlements 处理（去掉 `com.apple.developer.*`、注入两个 Hardened Runtime 例外）。
- 本项目在可行性验证阶段参考了其 `config.json`、`signatures.json`、`Resigner.swift` 的设计。

## sunnyyoung/WeChatTweak (AGPL-3.0)

- 上游项目；提供 3.8.x 的补丁点、多开/防撤回 CLI 结构和 4.x 的早期适配数据。

## TKkk-iOSer/WeChatPlugin-MacOS (MIT)

- 被重新实现的目标项目；提供旧版功能清单、交互和自动回复/远程控制的产品定义。
- 本项目不包含该项目的代码；仅在其功能目标上做新版可行性评估。

## fishhook (BSD-2-Clause)

- `tools/login_persist/vendor/fishhook.c` / `fishhook.h`
- Copyright (c) 2013, Facebook, Inc.；保留原始版权头和 BSD 许可文本。
- 仅用于登录态保持实验 dylib 的符号重绑定。

## Tencent WeChat

- 本项目不包含、不修改、不再分发微信客户端代码或资源。
- 用户需自行安装微信，并自行承担修改本地客户端的风险。

---

如果权利人对本项目中的某段数据/思路有异议，请开 issue，我们会删除或调整。
