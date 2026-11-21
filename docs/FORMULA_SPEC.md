# Formula 编写规范 / Formula Specification

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> 本规范仅适用于本**个人自用** Harmonybrew Tap（`nknkol/cask`），在 Homebrew 基础风格之上结合了鸿蒙 PC 平台的签名、`glibc` 兼容与内存态 ELF 补丁实践。

## 一、基础要求

1. **版本锁定**：`url` 与 `resource` 必须指向固定版本或固定 commit/tag，禁止使用浮动分支，并校验 `sha256`。
2. **许可证声明**：开源软件应声明 SPDX 格式的 `license`；闭源商业 CLI 可省略或注明专有许可。
3. **冒烟测试**：必须包含 `test do` 块（版本输出、帮助信息或核心功能验证；使用 `elf-patch-loader` 的配方需验证 `ELFPATCH_VERIFY=1`）。
4. **提交规范**：
   - 新增：`<formula> <version> (new formula)`
   - 升级：`<formula> <version>`（修订号升级如 `<formula> <version>_1: <summary>`）
   - 修复：`<formula>: <action>`

## 二、鸿蒙平台三类软件适配规范

### 2.1 闭源软件与 Linux 预编译二进制（推荐：`elf-patch-loader`）

对于上游仅提供 Linux ARM64 预编译包（`glibc` 或 `musl`）或存在鸿蒙 seccomp `SIGSYS` / 路径兼容性问题的软件（如 `antigravity`、`bun`、`claude-code`、`codex`），**统一推荐采用内存态 ELF 补丁加载器**：

- **原文件零改动**：上游二进制原封不动安装至 `libexec/`（权限 `0644`），不经过 `patchelf`，也无需对大体积主程序重新签名。
- **构建期签名加载器**：声明 `depends_on "nknkol/cask/binary-sign-tool" => :build`，在 `def install` 中调用 `patches/elf-patch-loader/install_loader.rb`，只对 29 KB 的加载器 `bin/<name>` 执行自签名并运行 `ELFPATCH_VERIFY=1` 校验。
- **动态链接 `glibc` 程序**：声明 `depends_on "nknkol/cask/glibc"`，并在 `.elfpatch` 中配置 `INTERP @GLIBC_INTERP@` 与 `RUNPATH @GLIBC_LIB@`，不导出全局 `LD_LIBRARY_PATH`，避免污染原生 musl 子进程。
- **规避鸿蒙 seccomp `SIGSYS`**：在 `.elfpatch` 中启用 `TRAP_SIGSYS`（零偏移、跨版本生效），或按需使用 `GO_SYM` / `REDIRECT_ADRP` / `SEARCH` / `OFFSET` 补丁。

> 不再推荐旧的“`post_install` 中调用 `binary-sign-tool-fix` 签名”做法——Bottle 内签好名后用户解包即可运行，不需要用户本机预装构建工具。

### 2.2 普通无需补丁的预编译 musl 二进制

若上游静态 musl ELF 无需任何运行时补丁（如早期 `magpie`、`sheldon`、`starship`）：
- 声明 `depends_on "nknkol/cask/binary-sign-tool" => :build`；
- 在 `def install` 构建阶段完成 `binary-sign-tool-fix sign -selfSign 1` 签名后再安装到 `bin/`，直接打入 Bottle。

### 2.3 源码编译软件

- `url` 指向官方源码包；
- 鸿蒙适配补丁统一存放在小写 `patches/<formula>/` 目录下，命名为 `0001-简短描述.patch`；
- 使用 `patch do` 块或在 `install` 中调用 `patch -p1` 应用补丁（声明 `depends_on "gpatch" => :build` 或使用系统 `patch`）；
- 使用鸿蒙 SDK 的 `lld` 链接时会自动注入签名，通常无需额外手动签名。

## 三、Bottle 与多版本归档规范

1. **主配方**：必须声明 `bottle do` 与 `root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2F<formula>"`，发布前将构建得到的 `arm64_ohos` `sha256` 写回配方。
2. **历史版本与退役配方归档（`Archive/Formula/<formula>@<version>.rb`）**：
   - 历史版本化配方与已被官方 `harmonybrew/core` 接管的退役配方统一移至 `Archive/Formula/`，其专属历史补丁同步移至 `Archive/patches/`；
   - 类名遵循 Homebrew 命名规则（如 `AntigravityAT152`、`CodexAT01621`）；
   - **必须**声明 `keg_only :versioned_formula`，避免与主配方链接冲突；
   - **不应**保留指向原主配方瓶子名的 `bottle do` 块（Homebrew 安装 `@version` 配方时会请求 `<formula>@<version>--<version>...` 导致 404）；历史瓶子资产继续保存在原 `bottles/<formula>` Release 中。

## 四、依赖声明

- 本 Tap 内部配方建议写全限定名：`depends_on "nknkol/cask/glibc"`、`depends_on "nknkol/cask/binary-sign-tool" => :build`；
- 仅构建期使用的工具（如 `cmake`、`make`、`gpatch`、`binary-sign-tool`）必须标注 `=> :build`；
- 第三方未封装源码依赖使用 `resource` 块并锁定版本与 `sha256`。

---

<a id="english"></a>

> [!NOTE]
> This specification applies specifically to this **personal** Harmonybrew tap (`nknkol/cask`), combining standard Homebrew conventions with HarmonyOS PC signing, keg-only `glibc`, and in-memory ELF patching practices.

## 1. General Requirements

1. **Pinned Sources**: `url` and `resource` entries must reference fixed versions, tags, or commits with verified `sha256` checksums.
2. **License**: Declare SPDX `license` for open-source packages (may be omitted for proprietary closed-source CLIs).
3. **Tests**: Provide a `test do` block covering version/help/smoke checks (formulae using `elf-patch-loader` should assert `ELFPATCH_VERIFY=1` passes).
4. **Commit Messages**:
   - New formula: `<formula> <version> (new formula)`
   - Version bump: `<formula> <version>` (or `<formula> <version>_1: <summary>` for revisions)
   - Fix: `<formula>: <action>`

## 2. Package Adaptation Rules on HarmonyOS

### 2.1 Closed-Source & Prebuilt Linux ARM64 Binaries (Preferred: `elf-patch-loader`)

For upstream prebuilt Linux ARM64 binaries (`glibc` or `musl`) or binaries affected by HarmonyOS seccomp `SIGSYS` / read-only `/tmp` issues (`antigravity`, `bun`, `claude-code`, `codex`):

- **Zero Disk Mutation**: Install the upstream ELF untouched into `libexec/` (`0644`) without `patchelf` or re-signing huge binaries.
- **Build-Time Loader Signing**: Declare `depends_on "nknkol/cask/binary-sign-tool" => :build` and invoke `patches/elf-patch-loader/install_loader.rb` inside `def install`. Only the 29 KB `bin/<name>` loader is signed, and `ELFPATCH_VERIFY=1` runs during install.
- **Dynamic `glibc` Binaries**: Declare `depends_on "nknkol/cask/glibc"` and set `INTERP @GLIBC_INTERP@` + `RUNPATH @GLIBC_LIB@` in `.elfpatch` (never export global `LD_LIBRARY_PATH` into child processes).
- **`SIGSYS` Immunity**: Enable `TRAP_SIGSYS` in `.elfpatch` for zero-offset cross-version `-ENOSYS` fallback, alongside declarative `GO_SYM` / `REDIRECT_ADRP` / `SEARCH` / `OFFSET` patches as needed.

> The legacy pattern of signing inside `post_install` is deprecated; signing at build time keeps bottles self-contained with zero build-tool runtime dependency.

### 2.2 Simple Prebuilt musl Binaries (No Runtime Patch Needed)

- Declare `depends_on "nknkol/cask/binary-sign-tool" => :build`.
- Sign during `def install` with `binary-sign-tool-fix sign -selfSign 1` before installing into `bin/`.

### 2.3 Source-Built Formulae

- Point `url` to the official source archive.
- Place HarmonyOS patches in lowercase `patches/<formula>/0001-short-description.patch`.
- Apply via `patch do` or `patch -p1` during `install`. Executables linked with OHOS SDK `lld` are signed automatically.

## 3. Bottles & Versioned Archives

1. **Primary Formulae**: Declare `root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2F<formula>"` and record the `arm64_ohos` bottle `sha256`.
2. **Archived & Retired Formulae (`Archive/Formula/<formula>@<version>.rb`)**:
   - Store historical versioned formulae and retired formulae (e.g. `deepseek-harness`) under `Archive/Formula/`, with their exclusive patches in `Archive/patches/`.
   - Use Homebrew's `AT` class naming (e.g. `AntigravityAT152`).
   - **Must** declare `keg_only :versioned_formula`.
   - **Must not** keep a stale `bottle do` block from the primary formula (Homebrew requests `<formula>@<version>--<version>...`, which 404s on the primary release). Keep historical bottle assets on the primary release.

## 4. Dependencies

- Qualify internal tap dependencies explicitly (`nknkol/cask/glibc`, `nknkol/cask/binary-sign-tool`).
- Mark build-only tools with `=> :build`.
- Pin third-party vendored dependencies in `resource` blocks with fixed versions and checksums.
