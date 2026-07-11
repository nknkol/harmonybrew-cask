# bun bootstrap 补丁说明

按序号依次应用。所有补丁针对 `bun v1.3.14` (commit `0d9b296af`)。

## 补丁列表

| 序号 | 文件名 | 涉及源文件 | 说明 |
|------|--------|-----------|------|
| 0001 | `0001-fix-platform-syscalls.patch` | `src/jsc/bindings/c-bindings.cpp` | `close_range` 返回 ENOSYS；`setvbuf` 注释掉 |
| 0002 | `0002-fix-resolver-traversal.patch` | `src/resolver/resolver.zig` | 目录遍历 EACCES → 空 DirInfo |
| 0003 | `0003-fix-hmdfs-filesystem.patch` | `src/cli/create_command.zig`<br>`src/install/PackageInstall.zig`<br>`src/install/isolated_install/Installer.zig`<br>`src/install/npm.zig`<br>`src/resolver/fs.zig` | hmdfs 不支持硬链接；包文件 symlink 按 hardlink 语义隐藏 realpath；禁用 O_TMPFILE/linkatTmpfile 路径；`bun create` 的 hardlink rename fallback copyfile |
| 0004 | `0004-fix-harmonyos-path-permissions.patch` | `src/cli/run_command.zig`<br>`src/install/PackageManager.zig` | `/tmp` 不可写但 `TMPDIR` 可用；不可读父目录作为 package.json 搜索边界 |

## 使用方法

```bash
cd bun-bun-v1.3.14
for p in 0001 0002 0003 0004; do
  git apply /path/to/patches/bun/${p}-*.patch
done
# 编译
bun run build:release:local --canary=off
```
