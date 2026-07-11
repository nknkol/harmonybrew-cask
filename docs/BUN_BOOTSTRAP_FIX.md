# bootstrap bun 补丁指南

在 `bun-bun-v1.3.14` 源码中应用 4 个补丁，然后重新编译。

## 应用补丁

```bash
cd ~/bun-bun-v1.3.14

# 先还原任何手动修改
git checkout -- src/jsc/bindings/c-bindings.cpp src/resolver/resolver.zig src/resolver/fs.zig src/install/PackageInstall.zig src/install/isolated_install/Installer.zig src/install/npm.zig src/cli/create_command.zig src/cli/run_command.zig src/install/PackageManager.zig

# 应用 4 个补丁
BASE="https://raw.githubusercontent.com/nknkol/harmonybrew-cask/main/patches/bun"
curl -sL "$BASE/0001-fix-platform-syscalls.patch" | git apply
curl -sL "$BASE/0002-fix-resolver-traversal.patch" | git apply
curl -sL "$BASE/0003-fix-hmdfs-filesystem.patch"   | git apply
curl -sL "$BASE/0004-fix-harmonyos-path-permissions.patch" | git apply
```

## 验证补丁已生效

```bash
# 补丁 1：close_range 走 ENOSYS fallback；禁用 OHOS setvbuf 崩溃路径
grep "OHOS kernel sends SIGSYS" src/jsc/bindings/c-bindings.cpp
grep "OHOS musl aborts" src/jsc/bindings/c-bindings.cpp

# 补丁 2：AccessDenied 容错
grep "AccessDenied" src/resolver/resolver.zig
# 应有 2 行输出

# 补丁 3：默认软链接；禁用 O_TMPFILE；隐藏 hardlink fallback 文件 symlink target
grep "Method.symlink" src/install/PackageInstall.zig
grep "use_o_tmpfile = false" src/install/npm.zig
grep "shouldExposeSymlinkTarget" src/resolver/fs.zig
grep "parent_dir.copyFile(\"gitignore\"" src/cli/create_command.zig

# 补丁 4：fake node 目录使用 TMPDIR；不可读父目录停止 package.json 搜索
grep "tmpdirPath()" src/cli/run_command.zig
grep "PermissionDenied" src/install/PackageManager.zig
```

以上 grep 都有输出 → 补丁正确应用。

## 编译

```bash
cd ~/bun-bun-v1.3.14
. /root/llvm21-env.sh 2>/dev/null || true
. "$HOME/.cargo/env" 2>/dev/null || true
export PATH="/usr/lib/llvm21/bin:$HOME/.bun/bin:$PATH"
export GIT_SHA=0d9b296af33f2b851fcbf4df3e9ec89751734ba4

ninja -C build/release -j6
# 产物在 build/release/bun
```

## 验证产物

```bash
./build/release/bun --version          # 应输出 1.3.14
./build/release/bun run --version      # 不应报 CouldntReadCurrentDirectory
./build/release/bun build ./test.ts    # 不应报 Cannot read directory /storage/
./build/release/bun install            # 不应报 EPERM: failed to link package
```

## 补丁说明

### 0001 — `src/jsc/bindings/c-bindings.cpp`

OHOS 对不支持的 `close_range` 可能触发异常，`setvbuf(stdout/stderr, nullptr, _IONBF, 0)` 也会导致崩溃。

**修复**：`close_range` 返回 `ENOSYS` 走 fallback；注释掉 `setvbuf`。

### 0002 — `src/resolver/resolver.zig`（两处）

模块解析遍历目录树时遇到无权限目录，只容错 `ENOENT`，不认 `AccessDenied`。

**修复**：两处 switch 分支加 `error.AccessDenied`。

### 0003 — hmdfs 文件系统

hmdfs 支持 symlink，不支持 hardlink；在 `/data/storage/el2/base/haps/entry/files` 下 `O_TMPFILE` 可以打开，但 `linkatTmpfile` 无法发布文件。

**修复**：默认安装方法改为 symlink；isolated installer 遇到 hardlink 失败 fallback copyfile；禁用 npm cache 的 O_TMPFILE 路径；resolver fs 扫描时对 `node_modules` 下文件 symlink 隐藏 target，模拟 hardlink 路径语义，同时保留目录 symlink target；`bun create` 生成 `.gitignore` 时 hardlink 失败 fallback copyfile。

### 0004 — 路径权限

鸿蒙 PC 上 `/tmp` 不可读写，但环境提供 `TMPDIR=/storage/Users/currentUser`。系统上层目录可能不可读，继续向上探测 `package.json` 会遇到权限边界。

**修复**：`bun run` 的 fake `node`/`bun` 目录使用 `RealFS.tmpdirPath()`；`bun install` 向上找 `package.json` 时遇到不可读父目录停止搜索，不影响当前目录 package.json 权限错误的正常报错。
