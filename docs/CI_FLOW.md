# CI 流程 / CI Workflow

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> 本仓库为个人自用 Homebrew Tap。日常大体积或需保留历史瓶子的 CLI 软件包通常在本地 `loh` Docker 容器内构建并用 `gh release upload --clobber` 增量上传；GitHub Actions CI 主要用于全自动构建或无需保留旧瓶子的配方。

## 触发方式

实际定义见 [`.github/workflows/bottle.yml`](../.github/workflows/bottle.yml)：

| 方式 | 操作 |
| :--- | :--- |
| **推送 tag** | `git tag -f bottles/<formula> && git push origin bottles/<formula> --force` |
| **手动触发** | GitHub Actions → **Build bottle** → **Run workflow** |

> 仅响应 `bottles/**` 标签推送与手动 `workflow_dispatch`，普通分支推送不会自动触发。

## 执行流程

```text
推送 tag bottles/<formula> 或手动触发 workflow_dispatch
          │
          ▼
┌──────────────────────────────┐
│ GitHub Actions Runner        │
│ runner: ubuntu-24.04-arm     │
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ DockerHarmony 容器           │
│ 1. sh ci-runner/build.sh     │  初始化工具链、安装 Harmonybrew
│ 2. brew tap 本地 /workspace   │  将当前工作区注册为 nknkol/cask
│ 3. brew install --build-bottle│ 构建/安装（含 elf-patch-loader 签名校验）
│ 4. brew bottle --skip-relocation --json │ 生成 .tar.gz + .json
│ 5. brew postinstall & brew test         │ 冒烟测试
│ 6. 合并 sha256 写回 Formula/            │
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ 发布到 GitHub Release        │
│ tag: bottles/<formula>       │
│ 资产: .tar.gz + .json        │
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ 提交并推送 Formula/ 到 main   │
│ commit: bottle: <formula>    │
└──────────────────────────────┘
```

> [!WARNING]
> **关于 Release 重建行为**：当前 `.github/workflows/bottle.yml` 在发布阶段会先 `gh release delete` 再 `gh release create`，从而清空同一个 `bottles/<formula>` Release 下的历史版本资产。如果该软件需要保留历史版本瓶子（如 `antigravity`、`bun`、`claude-code`、`codex`），请改用本地容器构建后执行 `gh release upload bottles/<formula> ... --clobber` 增量上传，切勿直接推送 `bottles/<formula>` 标签。

## 配置说明

### Workflow 输入参数（`workflow_dispatch`）

| 参数 | 说明 | 默认值 |
| :--- | :--- | :--- |
| `formula` | 配方名（如 `binary-sign-tool`） | 必填 |
| `software` | 产物子目录名 | 同 `formula` |
| `extra_packages` | 需提前安装的本 Tap 依赖（空格分隔） | 空 |
| `run_tests` | 是否执行 `brew test` | `true` |

### 所需权限与基础镜像

- 权限：`contents: write`（用于创建/更新 Release 及提交 Formula 更新）
- 镜像：`ghcr.io/hqzing/dockerharmony:latest`

## 相关文件

| 文件 | 作用 |
| :--- | :--- |
| [`.github/workflows/bottle.yml`](../.github/workflows/bottle.yml) | CI 工作流定义 |
| [`scripts/build-bottle.sh`](../scripts/build-bottle.sh) | 容器内统一构建、打包与测试脚本 |
| [`ci-runner/build.sh`](../ci-runner/build.sh) | Docker 容器环境初始化（工具链、SDK、Harmonybrew） |

---

<a id="english"></a>

> [!NOTE]
> This is a personal Homebrew tap. For large CLI packages or releases where historical bottle assets must be preserved, bottles are typically built locally in a `loh` Docker container and uploaded incrementally via `gh release upload --clobber`. GitHub Actions CI is kept for automated clean-slate builds.

## Triggers

Defined in [`.github/workflows/bottle.yml`](../.github/workflows/bottle.yml):

| Method | Action |
| :--- | :--- |
| **Push tag** | `git tag -f bottles/<formula> && git push origin bottles/<formula> --force` |
| **Manual dispatch** | GitHub Actions → **Build bottle** → **Run workflow** |

> Branch pushes do not trigger builds; only `bottles/**` tags and manual `workflow_dispatch` runs do.

## Pipeline Overview

1. Runs on `ubuntu-24.04-arm` inside `ghcr.io/hqzing/dockerharmony:latest`.
2. Bootstraps toolchains and Harmonybrew via `ci-runner/build.sh`.
3. Runs `scripts/build-bottle.sh`: taps `/workspace` as `nknkol/cask`, runs `brew install --build-bottle`, `brew bottle --skip-relocation --json`, `brew postinstall`, and `brew test`, then merges the bottle `sha256` into `Formula/<formula>.rb`.
4. Uploads `.tar.gz` and `.json` assets to GitHub Release `bottles/<formula>` and commits the updated formula back to `main`.

> [!WARNING]
> **Release Recreation Caveat**: `.github/workflows/bottle.yml` currently deletes and recreates `bottles/<formula>` on every run, wiping previous assets in that release. For formulae that keep multiple historical bottles (`antigravity`, `bun`, `claude-code`, `codex`), build locally and upload incrementally using `gh release upload bottles/<formula> <files...> --clobber` instead of pushing a `bottles/<formula>` tag.

## Workflow Inputs (`workflow_dispatch`)

| Input | Description | Default |
| :--- | :--- | :--- |
| `formula` | Formula name (e.g. `binary-sign-tool`) | Required |
| `software` | Artifact subdirectory name | Same as `formula` |
| `extra_packages` | Space-separated extra tap formulae to pre-install | Empty |
| `run_tests` | Whether to run `brew test` | `true` |

## Key Files

| File | Purpose |
| :--- | :--- |
| [`.github/workflows/bottle.yml`](../.github/workflows/bottle.yml) | GitHub Actions workflow |
| [`scripts/build-bottle.sh`](../scripts/build-bottle.sh) | In-container install, bottle, test, and sha256 merge script |
| [`ci-runner/build.sh`](../ci-runner/build.sh) | Docker toolchain, OHOS SDK, and Harmonybrew bootstrap |
