# bootstrap bun 手动修改指南

在 `bun-v1.3.14` 源码中做以下 3 处修改，然后重新编译。

---

## 1. `src/cli/run_command.zig` — bun run 启动时遍历 CWD 失败

**位置**：找到 `const root_dir_info = this_transpiler.resolver.readDirInfo(`

**原代码**：
```zig
const root_dir_info = this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir) catch |err| {
    if (!log_errors) return error.CouldntReadCurrentDirectory;
    ctx.log.print(Output.errorWriter()) catch {};
    Output.prettyErrorln("<r><red>error<r><d>:<r> <b>{s}<r> loading directory {f}", .{ @errorName(err), bun.fmt.QuotedFormatter{ .text = this_transpiler.fs.top_level_dir } });
    Output.flush();
    return err;
} orelse {
    ctx.log.print(Output.errorWriter()) catch {};
    Output.prettyErrorln("error loading current directory", .{});
    Output.flush();
    return error.CouldntReadCurrentDirectory;
};
```

**改为**：
```zig
const root_dir_info = readDirInfoIgnoreError: {
    if (this_transpiler.resolver.readDirInfo(this_transpiler.fs.top_level_dir)) |info| {
        break :readDirInfoIgnoreError info;
    } else |_| {
        break :readDirInfoIgnoreError null;
    }
};
```

**同时**，把下方 `if (root_dir_info.enclosing_package_json)` 改为：
```zig
if (root_dir_info) |info| {
    if (info.enclosing_package_json) |package_json| {
        // ... 原有逻辑保持不变 ...
    }
}
```
（原有 `if` 块结尾多一个 `}`）

---

## 2. `src/resolver/resolver.zig` — 模块解析遍历目录失败（两处）

**位置 1**：找到 `error.ENOENT, error.FileNotFound => {}`

**原代码**：
```zig
switch (@as(anyerror, err)) {
    error.ENOENT, error.FileNotFound => {},
```

**改为**：
```zig
switch (@as(anyerror, err)) {
    error.ENOENT, error.FileNotFound, error.AccessDenied => {},
```

**位置 2**：找到 `error.ENOENT, error.FileNotFound, error.ENOTDIR, error.NotDir => {}`

**原代码**：
```zig
switch (dir_entry.err.original_err) {
    error.ENOENT, error.FileNotFound, error.ENOTDIR, error.NotDir => {},
```

**改为**：
```zig
switch (dir_entry.err.original_err) {
    error.ENOENT, error.FileNotFound, error.ENOTDIR, error.NotDir, error.AccessDenied => {},
```

---

## 3. `src/install/PackageInstall.zig` — 硬链接失败回退软链接

**位置**：找到 `installWithHardlink` 函数内的 `linkatZ` 调用（约第 892 行）

**原代码**：
```zig
.file => {
    std.posix.linkatZ(entry.dir.cast(), entry.basename, destination_dir.fd, entry.path, 0) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
        std.posix.unlinkatZ(destination_dir.fd, entry.path, 0) catch {};
        try std.posix.linkatZ(entry.dir.cast(), entry.basename, destination_dir.fd, entry.path, 0);
    };
```

**改为**：
```zig
.file => {
    std.posix.linkatZ(entry.dir.cast(), entry.basename, destination_dir.fd, entry.path, 0) catch |err| {
        if (err != error.PathAlreadyExists) {
            // hmdfs doesn't support hardlinks; fall back to symlink
            if (err == error.AccessDenied or err == error.PermissionDenied) {
                std.posix.symlinkatZ(entry.path, destination_dir.fd, entry.path) catch |err2| {
                    return err2;
                };
                real_file_count += 1;
                continue;
            }
            return err;
        }
        std.posix.unlinkatZ(destination_dir.fd, entry.path, 0) catch {};
        try std.posix.linkatZ(entry.dir.cast(), entry.basename, destination_dir.fd, entry.path, 0);
    };
```

> **注意**：`real_file_count += 1` 和 `continue` 在原代码中会跳回到 while 循环。请确认在你的源码中继续使用 `continue` 而非 fall through。

---

## 验证

编译完成后测试：
```bash
./bun run --version          # 不应报 CouldntReadCurrentDirectory
./bun build ./test.ts        # 不应报 Cannot read directory /storage/
./bun install                # 不应报 EPERM: failed to link package
```
