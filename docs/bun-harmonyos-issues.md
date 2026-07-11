# bun on HarmonyOS 移植记录

## 鸿蒙 PC 文件系统特性

- 系统：HarmonyOS / HongMeng Kernel 1.12.0，aarch64
- hmdfs 支持软链接
- hmdfs 不支持硬链接
- `/tmp` 在当前环境不可读写
- 当前环境提供 `TMPDIR=/storage/Users/currentUser`
- `/storage/Users/currentUser/Workspace/...` 不支持 `O_TMPFILE`
- `/data/storage/el2/base/haps/entry/files` 支持 `O_TMPFILE` 打开匿名临时文件，但不支持把匿名临时文件发布成目录项
- 上层目录可能不可读，例如向上遍历到 `/storage/Users/` 时会遇到 `AccessDenied` / `PermissionDenied`
- 部分系统目录不可读但其中的文件可执行，例如 PATH 中的 bin 目录；不能用目录可读性判断可执行文件是否可用

## 实测结果

### 1. 硬链接

在工作区：

```text
os.link(src, dst) -> errno=1 Operation not permitted
```

在 `/data/storage/el2/base/haps/entry/files`：

```text
os.link(src, dst) -> errno=13 Permission denied
```

### 2. 软链接

在工作区和 `/data/storage/el2/base/haps/entry/files` 都可用：

```text
os.symlink("src", "sym") -> OK
```

### 3. `O_TMPFILE`

工作区：

```text
open(dir, O_TMPFILE | O_WRONLY) -> errno=95 Not supported
```

`/data/storage/el2/base/haps/entry/files`：

```text
open(dir, O_TMPFILE | O_WRONLY) -> OK
```

### 4. `linkatTmpfile`

在 `/data/storage/el2/base/haps/entry/files` 下，`O_TMPFILE` 创建出的匿名文件无法发布成可见文件：

```text
linkat(tmpfd, "", dirfd, "published", AT_EMPTY_PATH)
  -> errno=2 No such file or directory

linkat(AT_FDCWD, "/proc/self/fd/<tmpfd>", dirfd, "published", AT_SYMLINK_FOLLOW)
  -> errno=13 Permission denied
```

测试后目录中没有生成 `published` 文件。

### 5. 软链接与硬链接的可见差异

普通读写路径上，软链接和硬链接都能访问同一份目标内容。但以下系统调用行为不同：

- `lstat()`：软链接可见为 symlink，硬链接可见为普通文件
- `readlink()`：软链接有 target，硬链接没有 target
- `realpath()`：软链接会解析到目标路径，硬链接保持当前路径身份
- `unlink()` / `deleteTree()`：删除软链接和删除硬链接目录项语义不同，尤其目录 symlink 需要避免误删目标

## 源码关键位置

| 文件 | 行 | 作用 |
|------|----|------|
| `PackageInstall.zig` | 375 | `supported_method` 默认值（硬链接/软连接/复制） |
| `Installer.zig` | 617/854 | isolated installer 硬链接失败 fallback |
| `resolver/fs.zig` | 1355/1483 | symlink target 缓存；文件 symlink 按 hardlink fallback 语义隐藏 |
| `npm.zig` | 1047 | npm cache 写入；禁用 O_TMPFILE |
| `create_command.zig` | 634 | `bun create` 生成 `.gitignore` 时使用 `linkat` |
| `run_command.zig` | 603 | fake `node`/`bun` 目录；原版硬编码 `/tmp` |
| `PackageManager.zig` | 608 | `bun install` 从 cwd 向上寻找 `package.json` |

## 补丁状态

| 补丁 | 状态 | 备注 |
|------|------|------|
| 0001 | ✅ | close_range + setvbuf |
| 0002 | ✅ | resolver 目录遍历 EACCES |
| 0003 | ✅ | hmdfs hardlink/O_TMPFILE/fs symlink 语义合并补丁 |
| 0004 | ✅ | 路径权限：TMPDIR 与不可读父目录边界 |
