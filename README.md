# Harmonybrew Cask

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> **个人自用声明**：本仓库仅为作者个人在鸿蒙 PC（HarmonyOS / OpenHarmony `arm64_ohos`）上自用维护的非官方 Homebrew Tap，并非 Harmonybrew 官方仓库。配方、补丁策略及历史归档可能随时按个人需求调整或变更，不提供长期兼容性或稳定性 SLA，使用前请自行评估风险。

自定义 Homebrew Tap，用于在鸿蒙（OpenHarmony / HarmonyOS）平台上分发官方 `harmonybrew/core` 尚未收录、版本滞后、闭源预编译或需要特定平台补丁（如原生 ELF TLS、内存态 `SIGSYS` 拦截等）的命令行软件包。

## 快速使用

```sh
# 添加个人 Tap
brew tap nknkol/cask https://github.com/nknkol/harmonybrew-cask.git

# 建议使用带 Tap 前缀的完整名称，避免与 harmonybrew/core 同名配方冲突
brew install nknkol/cask/antigravity
brew install nknkol/cask/claude-code
brew install nknkol/cask/codex
brew install nknkol/cask/bun
brew install nknkol/cask/binary-sign-tool
```

## 当前主要配方

| 类型 | 代表配方 | 说明 |
| :--- | :--- | :--- |
| **内存态 ELF 补丁加载器** | `antigravity`、`bun`、`claude-code`、`codex` | 同时支持动态（`glibc`）与静态（`ET_DYN` 静态 PIE / `ET_EXEC` 静态 musl/Go）Linux ARM64 二进制；上游文件磁盘零修改，运行前通过 29 KB 的 [`elf-patch-loader`](patches/elf-patch-loader/README.md) 在内存中完成 `DT_RUNPATH` 注入、指令热补丁及 `TRAP_SIGSYS` 保护，构建期仅对加载器签名。 |
| **源码编译 + 平台补丁** | `binary-sign-tool`、`rust`（启用原生 ELF TLS）、`adbcli`、`hapsigntool`、`libgcc` | 从上游源码打补丁编译；其中 `rust` 补充了原生 `GeneralDynamic` ELF TLS 补丁（官方 `harmonybrew/core` 目前仍为 `emulated` TLS）。 |
| **运行库 / 预编译工具** | `glibc`（keg-only，含 GCC 运行库）、`magpie`、`sheldon`、`starship` | 提供鸿蒙补丁版 glibc 2.38 运行时及常用 CLI 工具（注：`deepseek-harness` 已由官方 `harmonybrew/core` 接管并归档至 `Archive/`；`sheldon`、`starship` 亦已进入官方源，可按需选用）。 |

## 多版本与退役配方归档

历史版本化配方（`<formula>@<version>.rb`）及已被官方 `harmonybrew/core` 接管的退役配方统一归档至 `Archive/Formula/`，对应专属历史补丁同步归档至 `Archive/patches/`，保持主目录 `Formula/` 与 `patches/` 仅包含现役配方：

```text
Formula/
├── antigravity.rb                ← 当前最新版 (1.5.4_1)
└── ...
Archive/
├── Formula/
│   ├── antigravity@1.5.2.rb      ← 历史版本归档
│   ├── deepseek-harness.rb       ← 已被 harmonybrew/core 接管归档
│   └── ...
└── patches/                      ← 归档配方对应的专属补丁
```

## 构建与发布方式

1. **本地容器构建（当前主力流程）**：在 `loh` 虚拟机或本地 Docker 容器中复用 `Harmonybrew` 构建环境，运行 `scripts/build-bottle.sh` 生成 Bottle 后，使用 `gh release upload bottles/<formula> ... --clobber` 向对应 Release 增量上传（避免覆盖历史瓶子）。详见 [`docs/LOCAL_BUILD.md`](docs/LOCAL_BUILD.md)。
2. **GitHub Actions CI**：支持手动 `workflow_dispatch` 或推送 `bottles/<formula>` 标签触发。注意当前 workflow 触发上传时会删除并重建对应 Release，详见 [`docs/CI_FLOW.md`](docs/CI_FLOW.md)。

## 目录结构

```text
├── Formula/                  # 现役主配方文件
├── patches/
│   ├── elf-patch-loader/     # 通用 AArch64 内存态 ELF 补丁加载器、TRAP_SIGSYS 与安装脚本
│   ├── antigravity/          # Antigravity .elfpatch 配置
│   ├── bun/                  # Bun .elfpatch 配置
│   ├── claude-code/          # Claude Code .elfpatch 配置
│   ├── codex/                # Codex .elfpatch 配置
│   ├── glibc/                # glibc 2.38 鸿蒙补丁与构建文档
│   ├── rust/                 # Rust 原生 ELF TLS 与自举补丁
│   └── ...                   # 其余现役软件包补丁
├── bootstrap/                # 运行时与自举构建所需归档
├── scripts/                  # Bottle 构建与本地辅助脚本
├── ci-runner/                # CI Docker 镜像与环境初始化脚本
├── Archive/                  # 历史版本化配方（@version）、退役配方及对应历史补丁
├── docs/                     # 使用、规范与移植文档
└── .github/workflows/
    └── bottle.yml            # GitHub Actions Bottle 构建流水线
```

## 文档索引

- 使用指南：[`docs/USAGE.md`](docs/USAGE.md)
- 内存 ELF 补丁加载器与 `TRAP_SIGSYS` 指南：[`patches/elf-patch-loader/README.md`](patches/elf-patch-loader/README.md)
- 配方规范与样板：[`docs/FORMULA_SPEC.md`](docs/FORMULA_SPEC.md) · [`docs/FORMULA_TEMPLATE.md`](docs/FORMULA_TEMPLATE.md)
- 本地构建与 CI 流程：[`docs/LOCAL_BUILD.md`](docs/LOCAL_BUILD.md) · [`docs/CI_FLOW.md`](docs/CI_FLOW.md)
- glibc 鸿蒙补丁说明：[`patches/glibc/README.md`](patches/glibc/README.md)

---

<a id="english"></a>

> [!NOTE]
> **Personal Tap Disclaimer**: This repository is a **personal** unofficial Homebrew tap maintained for the author's own use on HarmonyOS / OpenHarmony PC (`arm64_ohos`). It is **not** affiliated with the official `harmonybrew/core` repository. Formulae, patches, and historical archives may change or be removed without notice, with no stability or support SLA. Use at your own risk.

A personal Homebrew tap distributing CLI packages for HarmonyOS / OpenHarmony that are missing from official `harmonybrew/core`, closed-source/prebuilt, ahead of upstream core versions, or require platform-specific patches (such as native ELF TLS for Rust or in-memory `SIGSYS` syscall trapping).

## Quick Start

```sh
# Add this personal tap
brew tap nknkol/cask https://github.com/nknkol/harmonybrew-cask.git

# Prefer fully-qualified names to avoid collisions with harmonybrew/core
brew install nknkol/cask/antigravity
brew install nknkol/cask/claude-code
brew install nknkol/cask/codex
brew install nknkol/cask/bun
brew install nknkol/cask/binary-sign-tool
```

## Formula Categories

| Category | Examples | Notes |
| :--- | :--- | :--- |
| **In-Memory ELF Patch Loader** | `antigravity`, `bun`, `claude-code`, `codex` | Supports both dynamic (`glibc`) and static (`ET_DYN` static-PIE / `ET_EXEC` static musl or Go) Linux ARM64 ELF binaries. Upstream binaries remain untouched on disk; at launch, the 29 KB [`elf-patch-loader`](patches/elf-patch-loader/README.md) injects `DT_RUNPATH` (if dynamic), applies declarative in-memory patches, and optionally installs `TRAP_SIGSYS` guards. |
| **Source Build + Patches** | `binary-sign-tool`, `rust` (native ELF TLS), `adbcli`, `hapsigntool`, `libgcc` | Built from source with HarmonyOS patches. Notably, `rust` enables native `GeneralDynamic` ELF TLS (whereas official `harmonybrew/core/rust` still defaults to `emulated` TLS). |
| **Runtimes / Prebuilt Tools** | `glibc` (keg-only, bundled with GCC runtime libs), `magpie`, `sheldon`, `starship` | Patched glibc 2.38 runtime and utility CLIs. (`deepseek-harness` has been archived under `Archive/` after upstream adoption in `harmonybrew/core`; `sheldon` and `starship` are also available in official core.) |

## Archived & Historical Formulae

Pinned historical versions (`<name>@<version>.rb`) and retired formulae taken over by `harmonybrew/core` (such as `deepseek-harness`) are archived under `Archive/Formula/` alongside their dedicated patches in `Archive/patches/`, keeping `Formula/` and `patches/` focused on active packages:

```text
Formula/
├── antigravity.rb                ← Latest (1.5.4_1)
└── ...
Archive/
├── Formula/
│   ├── antigravity@1.5.2.rb      ← Archived version
│   ├── deepseek-harness.rb       ← Retired (in harmonybrew/core)
│   └── ...
└── patches/                      ← Patches for archived formulae
```

## Building & Publishing Bottles

1. **Local Container Build (Primary Workflow)**: Build bottles in a reusable HarmonyOS Docker container (e.g. `codex-bottle2` inside `loh`) via `scripts/build-bottle.sh`, then incrementally upload assets with `gh release upload bottles/<formula> ... --clobber` so historical bottle tarballs are preserved. See [`docs/LOCAL_BUILD.md`](docs/LOCAL_BUILD.md).
2. **GitHub Actions CI**: Triggered via `workflow_dispatch` or pushing tag `bottles/<formula>`. Note that the workflow recreates the release on upload; see [`docs/CI_FLOW.md`](docs/CI_FLOW.md).

## Documentation Index

- Usage Guide: [`docs/USAGE.md`](docs/USAGE.md)
- In-Memory ELF Patch Loader & `TRAP_SIGSYS`: [`patches/elf-patch-loader/README.md`](patches/elf-patch-loader/README.md)
- Formula Spec & Templates: [`docs/FORMULA_SPEC.md`](docs/FORMULA_SPEC.md) · [`docs/FORMULA_TEMPLATE.md`](docs/FORMULA_TEMPLATE.md)
- Local Build & CI Flow: [`docs/LOCAL_BUILD.md`](docs/LOCAL_BUILD.md) · [`docs/CI_FLOW.md`](docs/CI_FLOW.md)
- HarmonyOS glibc Patch Notes: [`patches/glibc/README.md`](patches/glibc/README.md)
