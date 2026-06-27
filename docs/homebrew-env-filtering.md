# Homebrew 环境变量过滤机制（为什么本地 brew test 会失败）

## 机制

Homebrew 启动时通过 `bin/brew` 严格过滤环境变量：

```bash
# bin/brew#L292
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# 只用白名单变量重建环境
exec /usr/bin/env -i "${FILTERED_ENV[@]}" /bin/bash -p brew.sh "$@"
```

白名单只包含 `HOME`、`SHELL`、`PATH`、`USER` 等基础变量。`env -i` 清空一切，然后用白名单重建。

PATH 只有四个系统路径：`/usr/bin`、`/bin`、`/usr/sbin`、`/sbin`。

Homebrew prefix 下的 `bin/`（如 `$(brew --prefix)/bin/cc`）**不在 PATH 中**。

## 影响

所有通过 `brew` 启动的子进程（`brew test`、`brew install-bundler-gems`、`bundle install` 等）都运行在这个受限环境里。

这意味着：
- `cc` 必须位于 `/usr/bin/cc` 或 `/bin/cc` 才能被找到
- 放在 `$(brew --prefix)/bin/cc` 的编译器在 `brew` 子进程中不可见
- 任何带 C 原生扩展的 gem（如 prism）在 `bundle install` 时会因找不到 `cc` 而失败

## 鸿蒙 PC 的特殊性

鸿蒙 PC 系统分区只读，无法写入 `/usr/bin`。因此**本地 PC 上无法通过 `brew test`**。

## 解决方案

在 CI 容器（DockerHarmony）中提前做好软链接，因为容器文件系统可写：

```sh
# ci-runner/build.sh 中已包含
ln -sf $(brew --prefix)/bin/cc /bin/cc
ln -sf $(brew --prefix)/bin/make /bin/make
```

`/bin` 在 PATH 白名单内，链接后 `cc` 可被 Homebrew 子进程找到。

## 开发规范

- **本地编译验证**：`brew install -s nknkol/cask/<formula>` 正常（install 阶段不触发 gem 安装）
- **测试验证**：推送 tag 触发 CI，在 DockerHarmony 容器中运行 `brew test`
- **不接受**在 PC 上绕过只读限制的 hack
