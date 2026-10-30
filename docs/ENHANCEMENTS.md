# 增强功能与运行时组件

## 窗口隐私

「增强 → 窗口隐私」开启后，补丁副本在录屏、屏幕共享和其他截图工具中会隐藏微信窗口。

实现方式：

- `tools/runtime/window_privacy.mm` 编译成 `libExtraWeChatRuntime.dylib`；
- 启动补丁副本时通过 `DYLD_INSERT_LIBRARIES` 注入；
- hook `NSWindow` 的创建、排序和 `setSharingType:`，把窗口设为 `NSWindowSharingNone`；
- 同时监听窗口事件并做低频扫描，覆盖已经存在的窗口；
- 只作用于微信进程，不修改系统设置，不上传任何数据。

限制：

- 这是 macOS 的窗口属性，效果取决于录屏/共享软件和系统版本，不能当作安全保证；
- 通知横幅、菜单栏、系统面板不受影响；
- 微信自带的截图/录屏也会看不到微信窗口，需要截微信界面时先关闭；
- 开启/关闭后需要重启补丁副本。

## 运行时组件

`tools/runtime/build.sh` 是独立构建脚本；`scripts/build_app.sh` 会把 dylib 放进
`ExtraWeChat.app/Contents/Resources/libExtraWeChatRuntime.dylib`。

GUI 只把 dylib 路径和 `EXTRAWECHAT_WINDOW_PRIVACY=1` 通过 `open --env` 传给副本。
如果副本没有 `com.apple.security.cs.allow-dyld-environment-variables`，功能会提示先
「更新副本」。

## 规划中的功能

以下功能需要 hook `parseRevokeXML` / 消息终结器，每个微信构建都要单独核对入口和字段：

- 自定义撤回提示（`{from}` / `{time}` / `{content}`）；
- 本机撤回记录（默认关闭，不上传）；
- 关键词提醒（本地通知，默认关闭）。

自动领红包属于自动执行资金操作，且维护成本高，不放进默认发布计划。

## 主题

「设置 → 外观」提供：

- 微信绿；
- 深海蓝；
- 日落橙；
- 紫罗兰；
- 石墨灰。

主题影响侧栏、卡片、按钮、页面背景和增强页图标；深浅色外观自动适配。
