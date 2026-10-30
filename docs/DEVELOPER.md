# 开发者页与适配

## 开发者页

侧栏「开发者」是只读诊断页，用来排查微信构建适配问题。它不会显示聊天内容，也不会显示
`login_keys.tsv` 里的 key 原文。

包含：

- **运行环境**：ExtraWeChat 版本、macOS、CPU、微信路径、Python、tools、
  runtime dylib、`revoke_profiles.json`、数据目录；
- **微信扫描**：构建号、渠道、匹配方式（内置配置 / 几何签名）、目标架构、签名代、
  silent / keeptip 状态、补丁地址、newmsgid 字段、delta、副本状态；
- **兼容性检查**：构建是否匹配、两套补丁点是否可用、副本是否创建、DYLD 是否允许、
  runtime dylib 是否存在、副本是否需要重建；
- **签名验证**：对主微信和副本执行 `codesign --verify --deep --strict`；
- **诊断报告**：复制/导出包含 `locate_revoke --json`、`install.py status --json`、
  副本 `status --json` 的文本报告；
- **工具入口**：重新扫描、打开 profiles、打开 tools、打开日志。

反馈兼容性问题时，附上「复制报告」的内容即可；不要上传完整 `wechat.dylib`。

## 适配流程

1. 读取 `CFBundleVersion`（构建号，不是营销版本号）；
2. 在 `tools/revoke_profiles.json` 查 `builds[build][arch]`；
3. 找到配置后逐字节校验 `expected`；不匹配则不写入；
4. 没有配置时，arm64 回退到 3 代 `parseRevokeXML` 几何签名；
5. 仍然没有唯一命中 → 显示「当前微信构建暂未适配」，拒绝猜测。

## 边缘情况

- **268880**：只支持 silent；keeptip 会明确提示改用 silent。
- **269602**：silent 使用分类函数桩，keeptip 使用 parseRevokeXML；配置是专门写的。
- **补丁已打**：定位器接受原始字节和已打补丁字节，可在 silent / keeptip 间切换。
- **配置字节不匹配**：退回几何签名；两者都失败才报错，并在错误中说明配置不匹配。
- **x86_64**：只保留构建配置，不提供自动定位；补丁入口会拒绝非 arm64，避免在 Intel 上
  写入未验证的补丁。
- **签名失败**：`install.py` 会尝试用原始 dylib + entitlements 快照回滚；回滚失败会明确
  报错，不会把失败当成功。
- **备份缺失**：如果 dylib 已打补丁但没有原始备份，拒绝覆盖，提示重装微信。

## 新增一个构建

1. 打开开发者页 →「复制报告」，或运行：

   ```bash
   python3 tools/locate_revoke.py --app /Applications/WeChat.app
   ```

2. 如果 `Match: profile`，该构建已有配置；
   如果 `Match: signature`，说明同代自动定位可用，可把地址加入 profiles；
   如果两者都没有，需要按 `docs/PATCH-270115.md` 第 7 节人工定位；
3. 在 `tools/revoke_profiles.json` 增加构建条目；
4. 增加 `tests/test_profiles.py` 的覆盖；
5. 在补丁副本上做真实撤回测试，再发布。

## 测试

```bash
python3 -m unittest discover -s tests -v
python3 tools/locate_revoke.py --app /Applications/WeChat.app
python3 tools/locate_revoke.py --app /Applications/WeChat.app --force-scan
```

当前测试覆盖构建表格式、expected/asm 长度、地址重叠、268880、269602 和 3 代签名几何。
