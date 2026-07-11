# bun on HarmonyOS 移植记录

## 基本条件

- HarmonyOS hmdfs：支持软连接，不支持硬链接
- bootstrap bun：基于 v1.3.14 源码，5 补丁编译

## 问题链

### 1. 硬链接失败

bun 上游用硬链接把全局缓存的文件连到 `node_modules/`：
```
~/.bun/install/cache/<pkg>@<ver>@@@1/ → node_modules/<pkg>/
```

hmdfs 不支持硬链接，补丁 0003 把 `supported_method` 从 `hardlink` 改为 `symlink`。

### 2. 软连接导致解析器追进缓存

硬链接文件"看起来像真实文件"——解析器留在 `node_modules/` 里，逐层往上能找过渡依赖。

软连接让解析器追进 `~/.bun/install/cache/`。缓存里没有过渡依赖的嵌套入口（因为提升优化把它们放在 `node_modules/.bun/<pkg>/node_modules/<dep>`），解析器从缓存出发找不到过渡依赖 → `bun build` 报 `Could not resolve`。

### 3. 补丁 0003 resolver 修复只拦了目录层

在 `resolver.zig:4117` 加了 `!isInsideNodeModules()`，防止目录级跟到缓存。

但文件级也有一层追踪（`resolver.zig:1079`），漏修了。第二次补 0003 加文件级守卫。

### 4. `isInsideNodeModules` 误杀 `.bun` 内部

补丁用 `isInsideNodeModules` 拦所有 `node_modules/` 内的快捷方式——误拦了 bun 的内部 `.bun` 存储。`.bun` 里有内部快捷方式帮助 bun 解析过渡依赖，被拦后 bun 的解析变残。

典型：锁文件把 `@lezer/lr` 放在 `node_modules/.bun/@lezer+lr@1.4.3/node_modules/@lezer/lr`——实际文件在这里。但 `isInsideNodeModules` 不跟 `.bun` 内快捷方式导致找不到。

### 5. 间歇性安装失败

构建日志每轮有 2-6 个包下载/提取失败（`IntegrityCheckFailed`、`Fail extracting tarball`）。补丁 0003/0004/0005 覆盖不完全，bun install 并发写盘时仍有部分路径静默失败。

## 源码关键位置

| 文件 | 行 | 作用 |
|------|----|------|
| `PackageInstall.zig` | 375 | `supported_method` 默认值（硬链接/软连接/复制） |
| `IsolatedInstaller.zig` | 948 | `.symlink_dependencies`——建嵌套快捷方式 |
| `Symlinker.zig` | 42 | `ensureSymlink`——快捷方式创建与错误处理 |
| `resolver.zig` | 1079 | 文件级快捷方式追踪 |
| `resolver.zig` | 4117 | 目录级快捷方式追踪 |
| `nipm.zig` | 1107 | `linkatTmpfile`——O_TMPFILE 硬链接写缓存 |

## 补丁状态

| 补丁 | 状态 | 备注 |
|------|------|------|
| 0001 | ✅ | close_range + setvbuf |
| 0002 | ✅ | resolver 目录遍历 EACCES |
| 0003 | ⚠️ | hardlink→symlink + resolver 拦 symlink；`isInsideNodeModules` 误杀 `.bun` |
| 0004 | ✅ | 剩余硬链接路径 fallback |
| 0005 | ❓ | Symlinker 重试逻辑未验证是否生效 |
