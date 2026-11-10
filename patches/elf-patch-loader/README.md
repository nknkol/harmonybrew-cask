# HarmonyOS 通用内存 ELF 补丁加载器 (`elf-patch-loader`) 维护指南

本目录提供 Harmonybrew Cask 通用的 **AArch64 内存态 ELF 补丁加载器**，用于在 **不修改上游二进制文件（零 `patchelf`、零磁盘字节改动、无需对大体积主程序重新签名）** 的前提下，在运行前内存中完成动态链接器切换、`DT_RUNPATH` 注入、环境变量注入以及指令/数据热补丁。

---

## 1. 目录结构

- `elf_patch_loader.c`：AArch64 纯系统调用（`-nostdlib -fPIE -pie -Wl,--no-dynamic-linker`）加载器源码。
- `elf-patch-loader`：预编译的无动态解释器静态 PIE 加载器模板二进制（约 23 KB）。
- `install_loader.rb`：供 `Formula/*.rb` 在 `def install` 中调用的通用安装与构建期校验脚本。
- 各软件补丁配置文件：
  - `patches/antigravity/agy.elfpatch`
  - `patches/bun/bun.elfpatch`
  - `patches/claude-code/claude.elfpatch`
  - `patches/codex/codex.elfpatch`

---

## 2. 核心原理与优势

1. **原文件零改动**：上游 ELF 二进制原封不动安装到 `libexec/`（权限 `0644`），不经过 `patchelf` 或 `binary-sign-tool`，彻底规避二进制自校验问题。
2. **极速启动与签名**：HarmonyOS 内核直接 `execve` 的 `bin/<name>` 仅为 **23 KB** 的已签名加载器；主程序通过 `pread64` 读入匿名内存后，通过 HarmonyOS `prctl(PR_HM_JIT = 0x6a6974)` 切换为 `PROT_READ | PROT_EXEC` 并刷新指令缓存（`dc cvau` + `ic ivau`），省去了内核对数百 MB 二进制进行 `.codesign` 校验的开销。
3. **内存态 `DT_RUNPATH` 注入**：加载器在 `maxva` 顶部额外映射一页内存，拷贝原 `PT_DYNAMIC` 表并追加 `DT_RUNPATH`，直接由 `glibc` 的 `ld-linux-aarch64.so.1` 解析依赖库，**无需导出 `LD_LIBRARY_PATH`**，不会污染被加载程序派生出的 HarmonyOS 原生子进程。
4. **多策略混合补丁匹配（自动匹配 + 跨版本精确地址兜底）**：每个 `TARGET` 支持按顺序排列多条候选规则（`GO_SYM`、`REDIRECT_ADRP`、`SEARCH`、`OFFSET`），命中第一条即生效。大多数软件小版本升级无需改动 `.elfpatch`。

---

## 3. `.elfpatch` 配置文件语法

### 3.1 全局指令

| 指令 | 说明 | 示例 |
| :--- | :--- | :--- |
| `PROGRAM <path>` | 被加载的真实 ELF 路径（相对路径基于配方根目录 `<prefix>` 解析，模板中可用 `@PROGRAM@`） | `PROGRAM @PROGRAM@` |
| `INTERP <path>` | 可选。覆盖 ELF 的 `PT_INTERP` 动态链接器（模板中可用 `@GLIBC_INTERP@`） | `INTERP @GLIBC_INTERP@` |
| `RUNPATH <path>` | 可选。在内存中向 `PT_DYNAMIC` 注入 `DT_RUNPATH`（模板中可用 `@GLIBC_LIB@`） | `RUNPATH @GLIBC_LIB@` |
| `ENV <KEY=VALUE>` | 可选。在跳入入口点前向进程初始栈 `envp` 注入或覆盖环境变量 | `ENV AGY_CLI_DISABLE_AUTO_UPDATE=true` |

### 3.2 补丁目标与候选规则（`TARGET`）

```text
TARGET <target_name> [REQUIRED|OPTIONAL]
  <候选规则 1（优先尝试，通常为自动符号/特征搜索）>
  <候选规则 2（备选特征或精确版本虚拟地址 OFFSET 兜底）>
```

支持以下 4 种候选规则（所有十六进制串均支持 `??` 或 `..` 作为单字节通配符；在 `<replace_hex>` 中使用 `??` 表示**保留原字节不变**）：

1. **`GO_SYM`（Go `.gopclntab` 符号自动定位）**
   ```text
   GO_SYM <go_func_name> <patch_off> <expect_hex|-> <replace_hex>
   ```
   - 自动扫描内存中的 Go `.gopclntab` 表（含 PIE `DT_RELA` 重定位解析），找到 `<go_func_name>` 函数入口虚拟地址 `sym_va`。
   - 在 `sym_va + patch_off` 处校验 `<expect_hex>`（传 `-` 则不校验），通过后写入 `<replace_hex>`。

2. **`REDIRECT_ADRP`（AArch64 `ADRP + ADD` 字符串/常量指针自动重定向）**
   ```text
   REDIRECT_ADRP <orig_bytes_hex> <new_bytes_hex> [multi]
   ```
   - 自动在已加载段中唯一定位 `<orig_bytes_hex>` 的虚拟地址 `lit_va`。
   - 将 `<new_bytes_hex>` 写入内存顶部扩展页，并自动扫描代码段中指向 `lit_va` 的 `ADRP Rd, page; ADD Rd, Rd, #off` 指令对，在内存中重编码为指向新数据地址（典型用途：如 `codex` 将只读 `/tmp/codex-daemon-` 重定向到 `/data/storage/el2/base/cache/cd-`）。

3. **`SEARCH` / `SEARCH_ALL`（带掩码通配符的特征码自动搜索）**
   ```text
   SEARCH <pattern_hex> <patch_off> <replace_hex> [multi]
   ```
   - `SEARCH` 仅扫描可执行代码段（`PF_X`），当模式长度为 4 的倍数时按 4 字节对齐步进，速度极快；`SEARCH_ALL` 扫描全部 `PT_LOAD` 段。
   - 默认要求全局**唯一命中 1 次**（若命中 0 次或多于 1 次则視為该候选未命中，自动尝试下一条候选，防止误改指令）；若末尾加 `multi` 则替换所有命中点。
   - 跨版本技巧：AArch64 的 `BL` / `B` 相对跳转偏移随版本变化，将该指令对应的 4 字节写为 `??????94` 或 `????????` 即可实现跨版本免维护匹配。

4. **`OFFSET`（精确虚拟地址兜底）**
   ```text
   OFFSET <vaddr_hex> <expect_hex|-> <replace_hex>
   ```
   - 直接在 ELF 虚拟地址 `<vaddr_hex>` 处校验 `<expect_hex>`，匹配后写入 `<replace_hex>`。可将多个历史/当前版本的 `OFFSET` 规则并列放在 `TARGET` 末尾作为兜底。

---

## 4. 日常更新软件版本流程

当 `antigravity`、`bun`、`claude-code`、`codex` 发布新版本时：

1. **归档旧配方**：将当前 `Formula/<name>.rb` 拷贝为 `Formula/<name>@<old_version>.rb`（类名改为 `<Name>AT<Version>`，加上 `keg_only :versioned_formula`）。
2. **更新版本号与哈希**：更新 `Formula/<name>.rb` 中的 `version`、`url`、`sha256`，并暂时清空 `bottle do` 中的 `sha256` 行。
3. **验证补丁是否自动适配（绝大多数时候无需改 `.elfpatch`）**：
   - 在构建阶段，`install_loader.rb` 会自动运行 `ELFPATCH_VERIFY=1 <prefix>/bin/<name>`。
   - 若输出 `[elf-patch] verification passed`，说明现有的 `GO_SYM` / `REDIRECT_ADRP` / `SEARCH` 规则已自动匹配新版本！
   - 若某个 `REQUIRED` 目标报错未匹配，可使用 `ELFPATCH_DEBUG=1` 查看具体未命中的 `TARGET`，在对应 `.elfpatch` 中补充新的 `SEARCH` 或 `OFFSET` 候选规则。
4. **使用 `loh` Docker 容器（`codex-bottle2`）构建 Bottle 并上传**：
   - 将更新后的 `Formula/` 与 `patches/` 同步至 `codex-bottle2:/workspace` 并提交。
   - 执行 `FORMULA=<name> SOFTWARE=<name> /bin/sh scripts/build-bottle.sh`。
   - 导出生成的 `.bottle.1.tar.gz` 重命名为标准 `.bottle.tar.gz`，同步修正 `.bottle.json` 中的 `root_url`、`rebuild: 0`、`filename` 与 `local_filename`。
   - 执行 `gh release upload bottles/<name> <bottle.tar.gz> <bottle.json> --clobber -R nknkol/harmonybrew-cask`。

---

## 5. 新增二进制补丁配方模板

只需在 `patches/<pkg>/<bin>.elfpatch` 编写补丁规则，并在 `Formula/<pkg>.rb` 中调用 `install_loader.rb`：

```ruby
  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "nknkol/cask/glibc" # 若上游二进制为 glibc 动态链接则添加

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def install
    tap_root = Pathname.new(__FILE__).dirname.parent
    system RbConfig.ruby, (tap_root/"patches/elf-patch-loader/install_loader.rb").to_s,
           "--binary", (buildpath/"upstream-bin").to_s,
           "--config", (tap_root/"patches/my-pkg/my-bin.elfpatch").to_s,
           "--prefix", prefix.to_s,
           "--name", "my-bin",
           "--glibc-lib", Formula["nknkol/cask/glibc"].opt_lib.to_s,
           "--sign-tool", sign_tool.to_s
  end

  test do
    assert_match "verification passed", shell_output("ELFPATCH_VERIFY=1 #{bin}/my-bin 2>&1")
    assert_match version.to_s, shell_output("#{bin}/my-bin --version")
  end
```

---

## 6. 调试环境变量

- `ELFPATCH_VERIFY=1`：仅加载目标 ELF 并在内存中执行所有补丁校验，打印每个 `TARGET` 命中的候选序号与虚拟地址后立即以 `0` 退出（不真正启动目标程序）。
- `ELFPATCH_DEBUG=1`：打印补丁命中日志后正常启动目标程序。
- `ELFPATCH_CONFIG=/path/to/custom.elfpatch`：临时指定自定义 `.elfpatch` 配置文件路径进行测试。

---

## 7. 源码重编译 vs 内存补丁加载：选型与适配经验总结

结合本仓库与官方 `harmonybrew/core` 在 `bun`、`codex`、`claude-code`、`antigravity` 上的实践，总结以下选型与适配经验：

### 7.1 各软件维护策略对比

1. **闭源软件（`antigravity`、`claude-code`）—— 必须使用内存补丁加载器**
   - 无上游源码可供重编译；其中 `claude-code` 本质上是内嵌了 `.bun` 段的 Bun Standalone 单文件可执行程序，其底层 Bun 运行时在鸿蒙内核上触发的 `close_range` 等系统调用崩溃只能通过内存补丁解决。
2. **包含复杂沙箱/套接字路径依赖的软件（`codex`）—— 内存补丁加载器功能更完整**
   - 官方 `harmonybrew/core/codex` 采用源码编译，但因主目录所在的 `hmdfs` 不支持 Unix Domain Socket，直接打补丁禁用了 `daemon_auto_start`（导致 `codex agents`、`codex queue`、远程控制不可用），且未打包 `codex-exec-server`。
   - 本仓库通过 `REDIRECT_ADRP` 在内存中将套接字目录模板 `\x0dcodex-daemon-\xc0\x00` 重定向至支持 Unix Socket 的 `/data/storage/el2/base/cache/cd-`，配合 `CODEX_HOME` 桥接完整保留了 `app-server daemon` 全部特性，且免去了漫长的 Rust/V8 编译耗时。
3. **重度依赖系统底层特性的大型运行时（`bun`）—— 双轨互补**
   - 官方 `harmonybrew/core/bun` 维护了 70+ 个源码补丁以编译原生 OHOS musl 版本（包含内置 `ohos_sign` 支持 `bun build --compile` 自动签名、复杂的 `epoll` 状态机防空转等）；
   - 本仓库的 `nknkol/cask/bun` 直接复用上游 `glibc` 预编译包 + 内存补丁，与 `claude-code` 共享同一套 Bun 补丁规则，可在上游发布新版本时实现 5 秒内零编译快速跟进。

### 7.2 鸿蒙移植补丁的 4 类必要性分级（以 Bun 71 个补丁为例）

在分析一个大型 Linux 软件迁移到鸿蒙所需补丁时，可按以下 4 类评估是否需要以及如何用内存补丁实现：

| 分类 | 典型问题举例 | 对 `glibc` 预编译二进制是否必须？ | 内存补丁注入方式 |
| :--- | :--- | :--- | :--- |
| **1. 编译链与 musl 符号缺失** | `--abi=ohos` 构建配置、OHOS `libc.so` `stdout` 链接桩需 `-fPIC`、`zstd` 缺 `qsort_r`、`c-ares` 缺 `getservbyport_r`、TinyCC 宏、N-API `libc++` 符号修饰 | **完全不需要**<br>上游二进制链接完整的 `glibc 2.38`，天然不存在 musl 缺函数与编译期问题。 | 无需注入 |
| **2. 鸿蒙 seccomp `SIGSYS` 系统调用拦截** | • `close_range` (`436`)<br>• `openat2` (`437`)<br>• `epoll_pwait2` (`441`)<br>• `fchmodat2` (`452`) | **必须处理（触发即 `SIGSYS` 崩溃）**<br>上游代码中通常已有 `ENOSYS` 回退逻辑，只因鸿蒙内核返回 `SIGSYS` 而非 `ENOSYS` 导致崩溃。 | **极易注入**：既可用 `SEARCH` 将 `svc #0` 改为返回 `-ENOSYS`（`mov x0, #-38`），也可用下文的 **`SIGSYS` 信号陷阱 Hook** 全局拦截。 |
| **3. 鸿蒙内核单点行为差异开关** | • **对 `memfd` 调 `fstat(2)` 返回 `EACCES`**（导致 `Bun.spawn` 大 Buffer stdio 失败）<br>• **`pidfd + epoll` 丢失子进程退出事件**（导致异步 `Bun.spawn` 偶发挂死）<br>• **PTY Master `tcsetattr(TCSADRAIN)` 报 `EACCES`**（导致终端 `setRawMode` 报错，影响 TUI）<br>• **`/tmp` 只读** | **重要（影响子进程与终端 TUI 稳定性）** | **可通过内存补丁注入**：<br>• `can_use_memfd()` 入口改 `mov w0, #0; ret`<br>• `SHOULD_USE_WAITER_THREAD` 静态布尔值置 `1`（或让 `pidfd_open` 返回 `-ENOSYS`）<br>• `tcsetattr` 的 `TCSADRAIN`/`TCSAFLUSH` 参数置 `0` (`TCSANOW`)<br>• `/tmp` 路径常量用 `REDIRECT_ADRP` 重定向 |
| **4. 新增独立模块或大规模状态机重构** | • `bun build --compile` 自动写入 `.codesign` 自签名 + `/proc/self/maps` 免读自身文件<br>• `epoll` 空缓冲区 `EPOLLOUT` 防空转状态机重构（400+ 行） | **非核心脚本必须，按需取舍** | 难以仅靠几字节指令替换完成；若需注入复杂逻辑，需采用下文的 **层级 2 / 层级 3 Hook 方案**。 |

---

## 8. 进阶演进：基于 `elf-patch-loader` 的三层 Hook 架构设计

`elf-patch-loader` 本质上是一个**在目标程序入口执行前完全掌控进程地址空间的加载与 Hook 容器**。因为加载器自身的代码段（`.text`）在跳转到目标程序后**依然常驻在进程内存中**，当遇到比单纯改几条指令更复杂的适配需求时，可按稳定性和复杂度从高到低采用以下三层 Hook 机制：

### 层级 1：`SIGSYS` 信号陷阱 Hook（零偏移、跨版本 100% 稳定）

**实测结论**：鸿蒙内核 seccomp 对受限系统调用（如 `436` `close_range`、`437` `openat2`、`441` `epoll_pwait2`、`452` `fchmodat2`）并非采用不可捕获的 `SECCOMP_RET_KILL_PROCESS`，而是发送**可被用户态捕获的 `SIGSYS` 信号（`SECCOMP_RET_TRAP`）**。

在 `elf-patch-loader` 跳转到目标入口前，通过 `rt_sigaction(SIGSYS, ...)` 注册一个常驻在加载器代码段中的 `SA_SIGINFO` 处理函数：

```c
static void sigsys_handler(int sig, siginfo_t *info, void *ucontext) {
    ucontext_t *uc = (ucontext_t *)ucontext;
    // info->si_syscall (或 uc->uc_mcontext.regs[8]) 为被拦截的系统调用号
    // uc->uc_mcontext.regs[0..5] 为系统调用的 6 个参数
    // 将返回值寄存器 x0 设为 -ENOSYS (-38)，libc 包装函数会自动设置 errno = ENOSYS 并返回 -1
    uc->uc_mcontext.regs[0] = (unsigned long long)(-38);
}
```

- **核心优势**：
  1. **彻底免除特征码与偏移维护**：无需在目标二进制中查找任何 `svc #0` 指令位置，跨版本 100% 稳定。
  2. **跨 `fork()` 自动继承**：`sigaction` 注册的信号处理函数在 `fork()` 出的子进程（`execve` 之前）中依然有效，天然覆盖子进程在 `fork()` 后、`execve()` 前调用 `close_range` 清理文件描述符的场景。
  3. **支持在信号处理函数中直接用 C 模拟系统调用**：不仅能返回 `-ENOSYS`，还可以根据 `info->si_syscall` 和 `regs[0..5]` 在信号处理函数里直接用 C 代码模拟对应的系统调用行为（例如用户态模拟 `close_range` 或 `openat2`）并把结果写回 `regs[0]`。

### 层级 2：`ld.so --preload` 动态符号级 Hook（针对 `glibc` 动态链接程序，不污染子进程）

传统的 `LD_PRELOAD` 环境变量之所以不能在鸿蒙上直接使用，是因为环境变量会继承给子进程（如 `/bin/sh`、`git` 等鸿蒙原生 musl 程序），导致动态库加载失败。

但由于 `elf-patch-loader` 是直接将 `ld-linux-aarch64.so.1` 作为入口点启动并构造栈参数的，可以直接在加载器传给 `ld.so` 的命令行参数中使用 `--preload`：

```text
ld-linux-aarch64.so.1 --library-path <glibc>/lib --preload <libohos_hook.so> <target.elf> [args...]
```

- **核心优势**：
  1. **零环境变量污染**：`--preload` 仅对当前这次 `ld.so` 启动的进程生效，派生出的任何子进程均不受影响。
  2. **用标准 C 语言实现任意复杂逻辑**：可在 `libohos_hook.so` 中通过 `dlsym(RTLD_NEXT, ...)` 按符号名拦截任意 `glibc` 函数，例如：
     - 拦截 `tcsetattr`：当 `optional_actions` 包含 `TCSADRAIN`/`TCSAFLUSH` 且返回 `EACCES` 时，自动以 `TCSANOW` 重试；
     - 拦截 `linkat`：当在 `hmdfs` 上硬链接失败时，自动回退为文件复制；
     - 拦截 `fstat`：针对 `memfd` 特殊处理。
  3. **跨版本 100% 稳定**：绑定的是 `glibc` 标准 ABI 导出符号名，无论上游如何升级版本或重排代码，均无需修改偏移。

### 层级 3：Inline Trampoline（内联跳板 Hook，针对静态编译或未导出内部函数）

对于静态链接程序（如 `claude-code`）或编译器直接内联 `svc #0`、不经过 `glibc` 符号表的内部函数：

- **实现方式**：
  1. 在 `elf-patch-loader` 的 `.text` 段（或 `maxva` 顶部额外映射的 `PROT_READ | PROT_EXEC` 跳板页）中编写 C 语言 Hook 函数。
  2. 在目标函数入口（或特定点位）写入 4 条指令（16 字节）长跳转跳板：
     ```asm
     ldr x16, #8      // 50 00 00 58
     br  x16          // 00 02 1f d6
     .quad <hook_va>  // 8 字节目标虚拟地址
     ```
- **稳定性评估与注意事项**：
  - **高稳定场景**：拦截函数入口并直接按标准 ARM64 AAPCS64 调用约定（参数 `x0~x7`，返回值 `x0`）替换整个函数行为（例如将 `can_use_memfd()` 入口替换为返回 `0`）。
  - **存在跨版本风险的场景**：拦截函数中间指令，或 Hook 被 LTO 内联优化 / 采用自定义寄存器分配的 Rust/Zig 内部私有函数。此类场景在跨大版本升级时可能因寄存器分配变化而需要重新核对反汇编，因此**优先推荐使用层级 1（`SIGSYS` 陷阱）和层级 2（`ld.so --preload` 符号拦截）**，仅在必要时使用层级 3。

