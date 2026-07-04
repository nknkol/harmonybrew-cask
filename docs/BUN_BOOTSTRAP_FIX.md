# bootstrap bun 补丁指南

在 `bun-v1.3.14` 源码中应用 3 个补丁，然后重新编译。

## 快速使用（推荐）

补丁文件位于仓库 `patches/bun/` 目录：

```bash
cd bun-src/
git apply 0001-fix-run-command-traversal.patch
git apply 0002-fix-resolver-traversal.patch
git apply 0003-fix-hardlink-fallback.patch
```

补丁可从 GitHub raw 获取：

```bash
BASE="https://raw.githubusercontent.com/nknkol/harmonybrew-cask/main/patches/bun"
curl -sL "$BASE/0001-fix-run-command-traversal.patch" | git apply
curl -sL "$BASE/0002-fix-resolver-traversal.patch"   | git apply
curl -sL "$BASE/0003-fix-hardlink-fallback.patch"    | git apply
```

---

## 补丁说明

### 0001 — `src/cli/run_command.zig`

`bun run` 启动时调用 `readDirInfo` 遍历目录，遇到无权限父目录直接崩溃。

**修复**：`readDirInfo` 失败 → 返回 null 而非报错退出。同时加空指针保护。

### 0002 — `src/resolver/resolver.zig`（两处）

模块解析遍历目录树时遇到无权限目录，只容错 `ENOENT`，不认 `AccessDenied`。

**修复**：两处 switch 分支加 `error.AccessDenied`。

### 0003 — `src/install/PackageInstall.zig`

hmdfs 不支持 `link()` 硬链接，`bun install` 默认用硬链接 → EPERM。

**修复**：默认方法 `Method.hardlink` → `Method.symlink`。

---

## 编译

```bash
cd bun-src/
# 需要已有 bootstrap bun 在 PATH 中
bun run build:release:local --canary=off
# 产物在 build/release-local/bun
```

## 验证

```bash
./bun --version
./bun run --version          # 不应报 CouldntReadCurrentDirectory
./bun build ./test.ts        # 不应报 Cannot read directory /storage/
./bun install                # 不应报 EPERM: failed to link package
```
