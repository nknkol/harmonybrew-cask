# 本地构建指南 / Local Bottle Build Guide

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> 本仓库为个人自用 Homebrew Tap。由于鸿蒙 PC 系统分区只读，本地无法直接跑 `brew test`（详见 [`docs/homebrew-env-filtering.md`](homebrew-env-filtering.md)），Bottle 构建与测试统一在 Docker 容器（如 `loh` 虚拟机中的 Docker）中完成。

## 方式一：使用 `scripts/local-build.sh`（通用本地 Docker 构建）

`scripts/local-build.sh` 复用常驻构建容器，自动完成 tap 同步 → `brew install --build-bottle` → `brew bottle --skip-relocation --json` → `brew test`。

### 前置条件

```bash
# 1. 构建本地 CI 镜像（注意必须在 ci-runner 目录作为构建上下文执行）
(cd ci-runner && DOCKER_BUILDKIT=0 docker build --no-cache -t ohosci:1.0 .)

# 2. 启动常驻容器并添加 tap
docker run -d --name ohosci-builder ohosci:1.0 /bin/sh -c 'while true; do sleep 3600; done'
docker exec -it ohosci-builder /bin/sh -lc '
  export PATH="/storage/Users/currentUser/.harmonybrew/bin:$PATH"
  brew tap --force nknkol/cask https://github.com/nknkol/harmonybrew-cask.git
'
```

### 常用命令

```bash
# 构建指定配方（install → bottle → test）
sh scripts/local-build.sh <formula>

# 跳过测试 / 卸载重装 / 跳过 brew update / 拉取产物到 ./artifacts/
sh scripts/local-build.sh <formula> --no-test
sh scripts/local-build.sh <formula> --fresh
sh scripts/local-build.sh <formula> --no-sync
sh scripts/local-build.sh <formula> --pull

# 进入容器交互调试
sh scripts/local-build.sh <formula> --shell

# 重建镜像
sh scripts/local-build.sh <formula> --rebuild
```

### 环境变量

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `IMAGE` | `ohosci:1.0` | Docker 镜像名 |
| `CONTAINER` | `ohosci-builder` | 常驻容器名 |
| `TAP` | `nknkol/cask` | Tap 全名 |
| `EXTRA_PACKAGES` | 空 | 需预装的本 Tap 依赖（空格分隔） |

---

## 方式二：在 `loh` 复用容器（如 `codex-bottle2`）内直接跑 `scripts/build-bottle.sh`（当前主力发布流程）

1. 将更新后的 `Formula/` 与 `patches/` 同步至容器 `/workspace` 并提交至容器本地分支，刷新容器内的 `nknkol/cask` Tap。
2. 在容器内运行：
   ```sh
   docker exec -w /workspace \
     -e HOMEBREW_NO_AUTO_UPDATE=1 \
     -e HOMEBREW_NO_INSTALL_CLEANUP=1 \
     -e FORMULA=<formula> \
     -e SOFTWARE=<formula> \
     codex-bottle2 /bin/sh scripts/build-bottle.sh
   ```
3. 将生成的 `.bottle.1.tar.gz` 导出到宿主机 `artifacts/<formula>-<version>/` 并规范化命名与 `.bottle.json`（`root_url` 指向 `https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2F<formula>`，`rebuild: 0`）。
4. 将新 Bottle `sha256` 写入 `Formula/<formula>.rb`，然后增量上传至 Release（保留历史版本）：
   ```sh
   gh release upload bottles/<formula> \
     artifacts/<formula>-<version>/<formula>-<version>.arm64_ohos.bottle.tar.gz \
     artifacts/<formula>-<version>/<formula>-<version>.arm64_ohos.bottle.json \
     --clobber -R nknkol/harmonybrew-cask
   ```
5. 提交并推送 `main` 分支。

---

<a id="english"></a>

> [!NOTE]
> This is a personal Homebrew tap. Because HarmonyOS PC's system partition is read-only, `brew test` and bottle packaging are executed inside a reusable Docker container (e.g. inside the `loh` Linux VM). See [`docs/homebrew-env-filtering.md`](homebrew-env-filtering.md).

## Option 1: Using `scripts/local-build.sh`

### Setup

```bash
# 1. Build the reusable image (use ci-runner/ as the Docker build context)
(cd ci-runner && DOCKER_BUILDKIT=0 docker build --no-cache -t ohosci:1.0 .)

# 2. Start the persistent container and tap nknkol/cask
docker run -d --name ohosci-builder ohosci:1.0 /bin/sh -c 'while true; do sleep 3600; done'
docker exec -it ohosci-builder /bin/sh -lc '
  export PATH="/storage/Users/currentUser/.harmonybrew/bin:$PATH"
  brew tap --force nknkol/cask https://github.com/nknkol/harmonybrew-cask.git
'
```

### Usage

```bash
sh scripts/local-build.sh <formula>             # Full install -> bottle -> test
sh scripts/local-build.sh <formula> --no-test   # Skip brew test
sh scripts/local-build.sh <formula> --fresh     # Uninstall existing version first
sh scripts/local-build.sh <formula> --no-sync   # Skip brew update
sh scripts/local-build.sh <formula> --pull      # Pull .tar.gz and .json into ./artifacts/
sh scripts/local-build.sh <formula> --shell     # Open an interactive shell in the container
```

## Option 2: Direct `scripts/build-bottle.sh` in a Reusable Container (Primary Release Flow)

1. Sync updated `Formula/` and `patches/` into `/workspace` inside the container (e.g. `codex-bottle2` in `loh`) and update its local tap.
2. Execute:
   ```sh
   docker exec -w /workspace \
     -e HOMEBREW_NO_AUTO_UPDATE=1 \
     -e HOMEBREW_NO_INSTALL_CLEANUP=1 \
     -e FORMULA=<formula> \
     -e SOFTWARE=<formula> \
     codex-bottle2 /bin/sh scripts/build-bottle.sh
   ```
3. Export the `.bottle.tar.gz` and normalized `.bottle.json` (`root_url` set to `bottles%2F<formula>`, `rebuild: 0`), merge the `sha256` into `Formula/<formula>.rb`, and upload incrementally:
   ```sh
   gh release upload bottles/<formula> <bottle.tar.gz> <bottle.json> --clobber -R nknkol/harmonybrew-cask
   ```
4. Commit and push `main`.
