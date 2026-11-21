# 仓库使用说明 / Repository Usage Guide

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> 本仓库仅为作者个人在鸿蒙 PC 上自用的非官方 Homebrew Tap，非官方社区渠道，内容可能随时调整。

## 安装软件

```zsh
# 添加个人 Tap
brew tap nknkol/cask https://github.com/nknkol/harmonybrew-cask.git

# 安装（建议始终带 nknkol/cask/ 前缀，避免与 harmonybrew/core 同名包冲突）
brew install nknkol/cask/antigravity
brew install nknkol/cask/binary-sign-tool

# 跳过 Bottle 从源码/原始包构建安装
brew install -s nknkol/cask/binary-sign-tool
```

## 目录结构

```text
├── Formula/                  # 现役主配方文件
├── patches/
│   ├── elf-patch-loader/     # 通用内存态 ELF 补丁加载器、TRAP_SIGSYS 与 install_loader.rb
│   ├── antigravity/          # agy.elfpatch
│   ├── bun/                  # bun.elfpatch
│   ├── claude-code/          # claude.elfpatch
│   ├── codex/                # codex.elfpatch
│   ├── glibc/                # glibc 2.38 补丁与构建文档
│   └── <formula>/            # 各源码配方的 .patch 文件
├── bootstrap/                # 运行时与自举归档
├── scripts/
│   ├── build-bottle.sh       # 容器内统一 Bottle 构建脚本
│   ├── local-build.sh        # 本地常驻容器构建封装
│   └── docker-test.sh        # 容器内 brew test 封装
├── ci-runner/                # CI Docker 镜像与初始化脚本
├── Archive/                  # 历史版本化配方（@version）、退役配方及对应历史补丁
├── docs/                     # 文档目录
└── .github/workflows/
    └── bottle.yml            # CI 工作流
```

## 开发与更新流程

### 1. 新增或修改配方

1. 编写或更新 `Formula/<name>.rb`（参考 [`docs/FORMULA_TEMPLATE.md`](FORMULA_TEMPLATE.md) 与 [`docs/FORMULA_SPEC.md`](FORMULA_SPEC.md)）。
2. 如为闭源或预编译 Linux ELF，优先编写 `patches/<name>/<bin>.elfpatch` 并调用 `patches/elf-patch-loader/install_loader.rb`（详见 [`patches/elf-patch-loader/README.md`](../patches/elf-patch-loader/README.md)）。
3. 如为源码编译软件，将补丁放入 `patches/<name>/`（小写 `patches/`）。
4. 本地容器验证（详见 [`docs/LOCAL_BUILD.md`](LOCAL_BUILD.md)）：
   ```bash
   sh scripts/local-build.sh <formula>
   ```

### 2. 发布 Bottle

- **推荐（本地容器增量发布，保留历史瓶子）**：
  1. 在容器内通过 `scripts/build-bottle.sh` 生成 `.bottle.tar.gz` 与 `.bottle.json` 并通过 `brew test`。
  2. 将 Bottle `sha256` 合并写回 `Formula/<formula>.rb`。
  3. 使用 `gh release upload` 增量追加至已有 Release：
     ```zsh
     gh release upload bottles/<formula> <bottle.tar.gz> <bottle.json> --clobber -R nknkol/harmonybrew-cask
     ```
  4. 提交并推送 `main` 分支。
- **备选（GitHub Actions CI）**：
  - 在 GitHub Actions → **Build bottle** → **Run workflow** 手动触发，或推送标签：
    ```zsh
    git tag -f bottles/<formula>
    git push origin bottles/<formula> --force
    ```
  - 注意：当前 CI 工作流会删除并重建 `bottles/<formula>` Release（会清空该 Release 下的旧版本资产）。

## Bottle 发布策略

- 每个主配方对应一个 Release：`bottles/<formula>`。
- 历史版本化配方（`<formula>@<version>.rb`）标记 `keg_only :versioned_formula`，不声明指向不存在版本化文件名的 `bottle do` 块；历史瓶子文件保留在原 `bottles/<formula>` Release 中。

---

<a id="english"></a>

> [!NOTE]
> This repository is a **personal** unofficial Homebrew tap maintained for the author's own use on HarmonyOS PC. Expect breaking changes or cleanup at any time.

## Installing Packages

```zsh
# Tap this personal repository
brew tap nknkol/cask https://github.com/nknkol/harmonybrew-cask.git

# Always prefer the qualified name to avoid colliding with harmonybrew/core
brew install nknkol/cask/antigravity
brew install nknkol/cask/binary-sign-tool

# Build/install from source instead of downloading a bottle
brew install -s nknkol/cask/binary-sign-tool
```

## Directory Layout

```text
├── Formula/                  # Active primary formulae
├── patches/
│   ├── elf-patch-loader/     # Universal in-memory ELF patch loader, TRAP_SIGSYS & install_loader.rb
│   ├── antigravity/          # agy.elfpatch
│   ├── bun/                  # bun.elfpatch
│   ├── claude-code/          # claude.elfpatch
│   ├── codex/                # codex.elfpatch
│   ├── glibc/                # glibc 2.38 HarmonyOS patch & build guide
│   └── <formula>/            # Source patches for active source-built formulae
├── bootstrap/                # Runtime / bootstrap archives
├── scripts/
│   ├── build-bottle.sh       # Container bottle build script
│   ├── local-build.sh        # Persistent local container helper
│   └── docker-test.sh        # Container brew test wrapper
├── ci-runner/                # Docker image & toolchain bootstrap script
├── Archive/                  # Archived @version formulae, retired formulae & their patches
├── docs/                     # Documentation
└── .github/workflows/
    └── bottle.yml            # GitHub Actions workflow
```

## Development & Release Workflow

### 1. Adding or Updating a Formula

1. Author or edit `Formula/<name>.rb` following [`docs/FORMULA_TEMPLATE.md`](FORMULA_TEMPLATE.md) and [`docs/FORMULA_SPEC.md`](FORMULA_SPEC.md).
2. For closed-source or prebuilt Linux ARM64 ELFs, prefer `patches/<name>/<bin>.elfpatch` + `patches/elf-patch-loader/install_loader.rb` (see [`patches/elf-patch-loader/README.md`](../patches/elf-patch-loader/README.md)).
3. For source builds, place patches under lowercase `patches/<name>/`.
4. Verify in a local container (see [`docs/LOCAL_BUILD.md`](LOCAL_BUILD.md)):
   ```bash
   sh scripts/local-build.sh <formula>
   ```

### 2. Publishing Bottles

- **Recommended (Incremental Local Upload, Preserves Older Bottles)**:
  1. Build and test inside the container using `scripts/build-bottle.sh`.
  2. Merge the bottle `sha256` into `Formula/<formula>.rb`.
  3. Upload assets incrementally without recreating the release:
     ```zsh
     gh release upload bottles/<formula> <bottle.tar.gz> <bottle.json> --clobber -R nknkol/harmonybrew-cask
     ```
  4. Commit and push to `main`.
- **Alternative (GitHub Actions CI)**:
  - Trigger manually via **GitHub Actions → Build bottle → Run workflow**, or push tag `bottles/<formula>`:
    ```zsh
    git tag -f bottles/<formula>
    git push origin bottles/<formula> --force
    ```
  - Caution: the CI workflow currently deletes and recreates `bottles/<formula>`, removing previously uploaded historical bottle assets in that release.

## Bottle Policy

- One GitHub Release per primary formula: `bottles/<formula>`.
- Archived versioned formulae (`<formula>@<version>.rb`) are `keg_only :versioned_formula` and should omit `bottle do` blocks referencing non-existent `@version`-prefixed bottle filenames.
