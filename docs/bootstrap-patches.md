# bun bootstrap 补丁说明

按序号依次应用。所有补丁针对 `bun v1.3.14` (commit `0d9b296af`)。

## 补丁列表

| 序号 | 文件名 | 涉及源文件 | 说明 |
|------|--------|-----------|------|
| 0001 | `0001-fix-platform-syscalls.patch` | `src/jsc/bindings/c-bindings.cpp` | `close_range` 返回 ENOSYS；`setvbuf` 注释掉 |
| 0002 | `0002-fix-resolver-traversal.patch` | `src/resolver/resolver.zig` | 目录遍历 EACCES → 空 DirInfo |
| 0003 | `0003-fix-hardlink-fallback.patch` | `src/install/PackageInstall.zig` | `supported_method` hardlink → symlink |
| 0004 | `0004-fix-all-hardlinks.patch` | `src/install/PackageInstall.zig`<br>`src/install/isolated_install/Installer.zig` | 剩余硬编码 `.hardlink` → `.symlink`；回退路径 `.hardlink` → `.symlink` |
| 0005 | `0005-fix-remaining-hardlink-symlink-issues.patch` | `src/install/PackageInstall.zig`<br>`src/install/npm.zig`<br>`src/install/TarballStream.zig`<br>`src/install/isolated_install/Installer.zig`<br>`src/install/isolated_install/Symlinker.zig` | ENOSYS/EPERM 回退覆盖；linkatTmpfile 静默跳过 |

## 使用方法

```bash
cd bun-bun-v1.3.14
for p in 0001 0002 0003 0004 0005; do
  git apply /path/to/patches/bun/${p}-*.patch
done
# 编译
bun run build:release:local --canary=off
```
