# Homebrew 环境变量过滤机制 / Homebrew Environment Filtering on HarmonyOS PC

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> 本仓库为个人自用 Homebrew Tap。本文解释为何无法在鸿蒙 PC 宿主机直接运行 `brew test`，以及容器内构建测试的原因。

## 机制

Homebrew 启动时通过 `bin/brew` 严格过滤环境变量：

```bash
# bin/brew
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# 只用白名单变量重建环境
exec /usr/bin/env -i "${FILTERED_ENV[@]}" /bin/bash -p brew.sh "$@"
```

白名单仅保留 `HOME`、`SHELL`、`PATH`、`USER` 等基础变量，`$(brew --prefix)/bin` 不在初始 `PATH` 中。

## 影响与鸿蒙 PC 特殊性

所有由 `brew` 派生的子进程（`brew test`、`brew install-bundler-gems` 等）均运行在该受限环境中：
- 依赖 `/usr/bin/cc` 或 `/bin/cc` 的扩展编译在鸿蒙 PC 宿主机上无法找到编译器（系统分区 `/usr/bin` 与 `/bin` 为只读，无法写入软链）。
- 因此本地宿主机不直接运行 `brew test`，也不在宿主机上做绕过只读分区的 hack。

## 解决方案

在可写根文件系统的 Docker 容器（`DockerHarmony`）中预先建立软链（已内置于 [`ci-runner/build.sh`](../ci-runner/build.sh)），并统一在容器内运行 `brew install --build-bottle`、`brew bottle` 与 `brew test`（详见 [`docs/LOCAL_BUILD.md`](LOCAL_BUILD.md)）。

---

<a id="english"></a>

> [!NOTE]
> Maintained for this personal Harmonybrew tap. Explains why `brew test` is executed inside Docker containers rather than directly on a HarmonyOS PC host.

## Mechanism

`bin/brew` sanitizes the environment with `env -i` and resets `PATH` to `/usr/bin:/bin:/usr/sbin:/sbin`, excluding `$(brew --prefix)/bin`.

## Why Local `brew test` Fails on HarmonyOS PC

Subprocesses invoked by Homebrew (such as `brew test` or `bundle install` for Ruby C extensions) look for `cc` and `make` inside those four system paths. Because HarmonyOS PC mounts system partitions read-only, symlinks cannot be placed in `/usr/bin` or `/bin` on the host.

## Solution

Run `brew install --build-bottle`, `brew bottle`, and `brew test` inside the writable `DockerHarmony` container where [`ci-runner/build.sh`](../ci-runner/build.sh) links `cc`, `clang`, `make`, and toolchains into `/bin` (see [`docs/LOCAL_BUILD.md`](LOCAL_BUILD.md)).
