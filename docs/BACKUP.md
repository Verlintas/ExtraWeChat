# 副本备份 / 恢复

## 备份什么

只备份补丁副本的 App：

```text
~/Applications/WeChatExtra.app
```

**不备份**聊天记录、媒体、登录态或 `login_keys.tsv`。恢复时也只替换 App，不改动共享的微信数据容器。

## 使用

增强页 →「副本备份」：

- 创建备份；
- 恢复最近备份；
- 打开备份目录。

命令行：

```bash
python3 tools/backup_copy.py list --json
python3 tools/backup_copy.py create --json
python3 tools/backup_copy.py restore --latest --json
python3 tools/backup_copy.py delete --name 20261030-235000 --json
```

## 实现

- 优先使用 APFS `cp -cR`（copy-on-write clone），几乎不占额外空间；
- 非 APFS 自动退回 `ditto`；
- 备份目录：`~/Library/Application Support/ExtraWeChat/backups/copies/`；
- 每个备份有 `manifest.json`（时间、构建号、大小、方法）；
- 恢复前把当前 App 改名为 `.before-restore-<时间>`，成功后再删除；
- 恢复失败会移回原 App；
- 备份/恢复要求补丁副本完全退出；恢复还要求原微信退出。

## 限制

- 不备份聊天数据；
- 不备份登录 key；
- 备份 App 仍是 ad-hoc 签名；
- 如果微信更新，旧备份里的构建号可能已过期，恢复后仍需要重建副本。
