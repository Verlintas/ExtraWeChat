# 安全策略

## 支持范围

安全修复只针对最新发布版本（当前 v0.1.8）。旧版本请先升级。

## 报告安全问题

请优先使用 GitHub 的 **Private vulnerability reporting**：

<https://github.com/Verlintas/ExtraWeChat/security/advisories/new>

不要在公开 issue 中放以下内容：

- `login_keys.tsv` 或任何 autoauth key；
- 聊天记录、联系人、二维码；
- 完整 `wechat.dylib` 或 `WeChat.app`；
- 未脱敏的开发者报告（如包含路径/账号信息）。

可以放：

- macOS 版本、微信构建号、渠道；
- `locate_revoke.py` 的文本输出；
- 脱敏后的错误日志；
- `shasum -a 256` 摘要。

## 安全模型

- 补丁默认只写入用户目录下的 `~/Applications/WeChatExtra.app`；
- 修改后的 App 使用 ad-hoc 签名，不是 Apple 公证签名；
- 窗口隐私使用 macOS `NSWindow.sharingType`，不是安全边界；
- 登录态保持仍属实验功能，key 保存在本机 0600 文件中，正式版应迁移 Keychain；
- 没有遥测、账号系统或聊天内容上传；
- 不提供内核扩展，不要求关闭 SIP。

## 已知限制

- 修改微信客户端违反腾讯用户协议，存在账号风险；
- 微信更新可能使补丁失效，需要重建副本；
- 本项目与腾讯无关，不处理微信服务端或账号封禁问题；
- 第三方依赖和参考项目见 `NOTICE.md`。
