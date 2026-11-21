# Claude Code on HarmonyOS

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> 属于个人自用 Homebrew Tap `nknkol/cask` 的适配说明。

## 当前方案（`2.1.322+`：`elf-patch-loader` 内存补丁）

当前 [`Formula/claude-code.rb`](../../Formula/claude-code.rb)（`2.1.322`）已全面迁移至通用内存态 ELF 补丁加载器（[`patches/elf-patch-loader`](../elf-patch-loader/README.md)）：

- **磁盘零改动**：上游 `linux-arm64-musl` 的 `claude` 单文件可执行程序（内嵌 `.bun` 段）原封不动存放在 `libexec/claude`，无需磁盘二进制改写或对 300+ MB 主程序重签名。
- **内存态声明式补丁（[`claude.elfpatch`](claude.elfpatch)）**：在运行前通过跨版本通配符 `SEARCH`（附精确 `OFFSET` 兜底）在内存中自动完成 5 处 Bun 运行时修复：
  1. `close_range_fallback`：跳过直调 `close_range` 触发回退；
  2. `close_range_wrapper`：让 `close_range` 封装直接返回 `-1`；
  3. `close_range_fd3`：跳过 `close_range(3, ~0U, CLOEXEC)`；
  4. `bun_process_init_setvbuf`：跳过启动期导致 musl 异常的 `setvbuf(stdout/stderr, NULL, _IONBF, 0)`；
  5. `process_init_close_range`：跳过进程初始化阶段的 `close_range(4, ~0U, CLOEXEC)`。
- **构建期校验**：安装与 `brew test` 时自动执行 `ELFPATCH_VERIFY=1 bin/claude` 确认 5 处目标全部命中。

## 历史版本说明

历史归档配方 `Formula/claude-code@2.1.292.rb` 与 `Formula/claude-code@2.1.318.rb` 仍保留旧的离线二进制修补脚本 [`patch-bun-runtime.rb`](patch-bun-runtime.rb) 供参考或源码重建使用。

---

<a id="english"></a>

> [!NOTE]
> Maintained as part of the personal Harmonybrew tap `nknkol/cask`.

## Current Architecture (`2.1.322+`: `elf-patch-loader`)

[`Formula/claude-code.rb`](../../Formula/claude-code.rb) (`2.1.322`) uses the universal in-memory ELF patch loader ([`patches/elf-patch-loader`](../elf-patch-loader/README.md)):

- **Pristine Upstream Binary**: The upstream `linux-arm64-musl` standalone Bun executable is installed untouched to `libexec/claude` (`0644`); only the 29 KB loader at `bin/claude` is signed.
- **Declarative In-Memory Patches ([`claude.elfpatch`](claude.elfpatch))**: Applies 5 Bun runtime compatibility patches in memory before execution via wildcard `SEARCH` rules (with exact `OFFSET` fallbacks):
  1. `close_range_fallback` — force Bun's fd-loop fallback;
  2. `close_range_wrapper` — make the generic `close_range` wrapper return `-1`;
  3. `close_range_fd3` — skip `close_range(3, ~0U, CLOEXEC)`;
  4. `bun_process_init_setvbuf` — skip process-init `setvbuf(stdout/stderr, NULL, _IONBF, 0)` calls on musl;
  5. `process_init_close_range` — skip process-init `close_range(4, ~0U, CLOEXEC)`.
- **Build-Time Verification**: `ELFPATCH_VERIFY=1` validates all 5 targets during both `install` and `test`.

## Historical Versions

Archived formulae `Formula/claude-code@2.1.292.rb` and `Formula/claude-code@2.1.318.rb` continue to reference the legacy offline ELF patcher [`patch-bun-runtime.rb`](patch-bun-runtime.rb).
