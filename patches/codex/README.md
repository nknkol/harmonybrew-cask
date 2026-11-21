# OpenAI Codex on HarmonyOS

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> 属于个人自用 Homebrew Tap `nknkol/cask` 的适配说明。

## 当前方案（`0.167.0_1+`：`elf-patch-loader` 内存补丁）

当前 [`Formula/codex.rb`](../../Formula/codex.rb)（`0.167.0_1`）安装上游完整的 `codex-package-aarch64-unknown-linux-musl` 包结构（保留 `codex-package.json`、`bin/`、`codex-path`、`codex-resources` 以支持 daemon 包发现与复制），并已将主程序 `codex` 与 `codex-exec-server` 全面迁移至通用内存态 ELF 补丁加载器（[`patches/elf-patch-loader`](../elf-patch-loader/README.md)）：

- **磁盘零改动**：上游 `codex` 与 `codex-exec-server` 原封不动放在 `libexec/bin/*.real`，无需离线修改 `.init` 段、无需对大体积可执行文件重签名。
- **内存态声明式补丁（[`codex.elfpatch`](codex.elfpatch)）**：
  1. `daemon_socket_dir`（`REDIRECT_ADRP`）：自动定位只读格式字面量 `\x0dcodex-daemon-\xc0\x00`，将其对应的 `ADRP + ADD` 指针在内存中重定向至可创建 Unix Domain Socket 的 `/data/storage/el2/base/cache/cd-`（控制 `sockaddr_un.sun_path` 在 108 字节限制内，同时完整保留 `codex` daemon 特性）。
  2. `close_range_site_1` / `close_range_site_2`（`SEARCH` + `OFFSET` 兜底）：将非 PTY 子进程启动路径中的两处 `close_range(..., CLOSE_RANGE_CLOEXEC)` 的 `BL syscall` 替换为 `MOV X0, #-1`，使其自动回退至上游 `/proc/self/fd` + `fcntl(FD_CLOEXEC)` 清理逻辑，避免鸿蒙 `SIGSYS` 崩溃。
- **辅助兼容层**：
  - 私有 `ps` shim：响应 daemon 的 `ps -p PID -o stat= -o lstart=` 查询（鸿蒙 toybox `ps` 缺少 `lstart`）。
  - 随包自带的 `rg` 与语音辅助程序通过 `nknkol/cask/glibc` 运行，`zsh` 桥接至 Harmonybrew 原生 `zsh`。
- **主机运行注意**：`CODEX_HOME` 建议位于应用私有目录（如 `/data/storage/el2/base/files/...`），因为共享 `/storage`（`hmdfs`）不支持 Unix Socket 所需的属主与权限语义。

## 历史版本说明

- 历史归档配方 `Formula/codex@0.162.1.rb` 使用独立冻结的离线补丁脚本 [`patch-harmonyos-0.162.1.rb`](patch-harmonyos-0.162.1.rb)。
- 旧版 `0.167.0` 离线补丁脚本 [`patch-harmonyos.rb`](patch-harmonyos.rb) 已被 `codex.elfpatch` 取代，不再被当前配方引用。

---

<a id="english"></a>

> [!NOTE]
> Maintained as part of the personal Harmonybrew tap `nknkol/cask`.

## Current Architecture (`0.167.0_1+`: `elf-patch-loader`)

[`Formula/codex.rb`](../../Formula/codex.rb) (`0.167.0_1`) installs the full upstream `codex-package-aarch64-unknown-linux-musl` layout (keeping `codex-package.json`, `bin`, `codex-path`, and `codex-resources` intact for daemon package discovery/copying) and runs both `codex` and `codex-exec-server` through [`patches/elf-patch-loader`](../elf-patch-loader/README.md):

- **Pristine Upstream ELFs**: Unmodified `codex` and `codex-exec-server` binaries live in `libexec/bin/*.real`; only the tiny loaders are signed.
- **Declarative In-Memory Patches ([`codex.elfpatch`](codex.elfpatch))**:
  1. `daemon_socket_dir` (`REDIRECT_ADRP`): Automatically rewrites `ADRP + ADD` references from `\x0dcodex-daemon-\xc0\x00` to `/data/storage/el2/base/cache/cd-` in memory, enabling Unix Domain Sockets while staying within the 108-byte `sockaddr_un.sun_path` limit and preserving full daemon functionality.
  2. `close_range_site_1` / `close_range_site_2` (`SEARCH` with `OFFSET` fallback): Replaces the two `BL syscall` calls for `close_range(..., CLOSE_RANGE_CLOEXEC)` in the non-PTY launch path with `MOV X0, #-1`, activating upstream's `/proc/self/fd` + `fcntl(FD_CLOEXEC)` fallback instead of triggering HarmonyOS `SIGSYS`.
- **Companion Shims**: Includes a private `ps` shim for `-p PID -o stat= -o lstart=` (missing from HarmonyOS toybox `ps`), runs bundled Linux `rg`/voice helpers against `nknkol/cask/glibc`, and bridges `zsh` to native Harmonybrew `zsh`.
- **Runtime Note**: Keep `CODEX_HOME` on an app-private filesystem (e.g. `/data/storage/el2/base/files/...`) because shared `/storage` (`hmdfs`) lacks required Unix socket ownership/mode semantics.

## Historical Versions

- `Formula/codex@0.162.1.rb` uses the frozen offline patcher [`patch-harmonyos-0.162.1.rb`](patch-harmonyos-0.162.1.rb).
- The previous offline `0.167.0` patcher [`patch-harmonyos.rb`](patch-harmonyos.rb) is superseded by `codex.elfpatch` and no longer referenced by active formulae.
