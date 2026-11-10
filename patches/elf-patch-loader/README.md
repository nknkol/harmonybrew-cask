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
