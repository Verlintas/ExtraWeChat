# NOTICE / 第三方致谢

本项目（ExtraWeChat）的代码以 AGPL-3.0 发布。以下项目提供了 4.x 补丁点、几何签名或重签思路的
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

## Tencent WeChat

- 本项目不包含、不修改、不再分发微信客户端代码或资源。
- 用户需自行安装微信，并自行承担修改本地客户端的风险。

---

如果权利人对本项目中的某段数据/思路有异议，请开 issue，我们会删除或调整。
