# bootstrap bun 补丁指南

在 `bun-bun-v1.3.14` 源码中应用 3 个补丁，然后重新编译。

## 应用补丁

```bash
cd ~/bun-bun-v1.3.14

# 先还原任何手动修改
git checkout -- src/cli/run_command.zig src/resolver/resolver.zig src/install/PackageInstall.zig

# 应用 3 个补丁
BASE="https://raw.githubusercontent.com/nknkol/harmonybrew-cask/main/patches/bun"
curl -sL "$BASE/0001-fix-run-command-traversal.patch" | git apply
curl -sL "$BASE/0002-fix-resolver-traversal.patch"   | git apply
curl -sL "$BASE/0003-fix-hardlink-fallback.patch"    | git apply
```

## 验证补丁已生效

```bash
# 补丁 1：orelse 路径也创建空 DirInfo
grep -A5 "orelse" src/cli/run_command.zig | grep "getOrPut"
# 应有输出：var entry = try this_transpiler.resolver.dir_cache.getOrPut

# 补丁 2：AccessDenied 容错
grep "AccessDenied" src/resolver/resolver.zig
# 应有 2 行输出

# 补丁 3：默认软链接
grep "Method.symlink" src/install/PackageInstall.zig
# 应有输出
```

三条 grep 都有输出 → 补丁正确应用。

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

### 0001 — `src/cli/run_command.zig`

`bun run` 启动时调用 `readDirInfo` 遍历目录树，遇到无权限父目录返回 null。原代码仅处理了 err 分支，orelse（null）分支仍报错退出。

**修复**：`catch`（AccessDenied 错误）和 `orelse`（null）两路径都通过 `dir_cache.getOrPut` + `put` 创建空 DirInfo，函数签名不变。

### 0002 — `src/resolver/resolver.zig`（两处）

模块解析遍历目录树时遇到无权限目录，只容错 `ENOENT`，不认 `AccessDenied`。

**修复**：两处 switch 分支加 `error.AccessDenied`。

### 0003 — `src/install/PackageInstall.zig`

hmdfs 不支持 `link()` 硬链接，`bun install` 默认用硬链接 → EPERM。

**修复**：默认方法 `Method.hardlink` → `Method.symlink`。
