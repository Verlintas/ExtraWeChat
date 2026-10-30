# 微信 / macOS 兼容性

## 平台

| 项目 | 支持 |
| --- | --- |
| CPU | **Apple Silicon（arm64）** |
| macOS | **13 Ventura 及以上**；开发机实测 macOS 27.0.1 |
| 微信 | macOS 4.x，**42 个构建已内置**；同代构建可自动定位 |
| 不支持 | Intel（x86_64）、微信 3.8.x、4.1.7（逻辑在主程序） |

补丁副本方案只在用户目录写入，不修改 `/Applications/WeChat.app`，不需要 root、
不需要关闭 SIP、不需要内核扩展，因此对 macOS 版本的依赖很小。GUI 使用 macOS 13
已有的 SwiftUI API；更老的 macOS 未测试。

## 防撤回适配方式

### 1. 内置构建配置（首选）

`tools/revoke_profiles.json` 按 `CFBundleVersion`（构建号）保存每个构建的
silent / keeptip 补丁点和原始字节。写入前会逐字节校验，构建号或字节不匹配就拒绝。

已内置的 4.x arm64 构建：

| 签名代 | 构建号 |
| --- | --- |
| 4.1.10–4.1.11 | 268575, 268596, 268597, 268599, 268601, 268602, 268831, 268849, 268850, 268851, 269077, 269079, 269110, 269111, 269136 |
| 4.1.10–4.1.11（仅 silent） | 268880 |
| 4.1.12 | 269332, 269333, 269334, 269338, 269340, 269341 |
| 4.1.13+ | 269574, 269575, 269576, 269577, 269578, 269579, 269619, 269624, 269626, 269627, 269628, 269631, 270090, 270100, 270102, **270115（实测）**, 270132, 270134, 270135 |
| 269602 特殊 | 269602（silent 用分类函数桩；keeptip 用 parseRevokeXML） |

> 构建号才是唯一标识；同一个营销版本（例如 4.1.15）可能有多个构建号，地址不同，不能互套。
> 官网版和 App Store 版即使构建号相同，也以原始字节校验为准。

### 2. arm64 几何签名自动定位

未列入上表的构建，只要 `parseRevokeXML` 仍属于以下三代之一，就能自动定位：

| 代 | 特征 |
| --- | --- |
| 4.1.13+ | `cbz 40100034`，`delta 0x7a0`，`str 60E600F9` |
| 4.1.12 | `cbz 40100034`，`delta 0x7a0`，`str 60CE00F9` |
| 4.1.10–4.1.11 | `cbz E00F0034`，`delta 0x794`，`str 60B600F9` |

定位器要求两个锚点同时命中且全二进制唯一；命中多处会拒绝猜测。
`--force-scan` 可以强制走几何扫描，用于验证内置配置和自动定位结果一致。

### 3. 未适配

如果构建重编译了 `parseRevokeXML`，几何签名全部不中，GUI 会显示
「当前微信构建暂未适配」，不会写入任何字节。

## 远程适配表

`tools/revoke_profiles.json` 会随 App 打包，但也可以在运行时更新：

```bash
python3 tools/profile_update.py update --json
```

文件下载到 `~/Library/Application Support/ExtraWeChat/profiles/`，并校验 SHA。
本地表优先；如果本地表构建数少于内置表，自动回退内置表。
微信更新后不必等新版 ExtraWeChat，只要远端表已经收录新构建号。

## 新增一个微信构建

1. 在目标微信上运行只读定位：

   ```bash
   python3 tools/locate_revoke.py --app /Applications/WeChat.app
   ```

2. 如果显示 `Match: signature`，说明同代自动定位可用。可把结果记入
   `tools/revoke_profiles.json` 的本构建条目；也可以先直接用。
3. 如果显示 `no exact profile and no arm64 geometry hit`：
   - 用 `lipo -thin arm64` 抽取 `wechat.dylib`；
   - 找到 `parseRevokeXML` 的 `cbz` / `str newmsgid` 两个点；
   - 在 `tools/revoke_profiles.json` 增加 `generations` 条目，或增加该构建的精确配置；
   - 更新 `tests/test_profiles.py`；
   - 用副本做真实撤回测试后再发布。
4. 提 Issue 时请提供：微信版本、`CFBundleVersion`、渠道（App Store/官网）、
   定位器输出（不要上传完整 `wechat.dylib`）。

## macOS 版本说明

- 当前构建目标是 macOS 13+，App 为 arm64。
- 补丁副本用 `ditto` 复制、`codesign` 重签；这些工具在 macOS 13–27 都存在。
- 首次打开未公证 App 仍需右键打开或 `xattr -dr com.apple.quarantine`。
- GUI 依赖 `/usr/bin/python3`；没有 Xcode Command Line Tools 的机器需要先安装。
- 不提供 kext、不关闭 SIP、不修改系统 TCC 数据库。
