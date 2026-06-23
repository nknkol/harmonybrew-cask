# CI 流程

## 触发方式

| 方式 | 操作 |
|------|------|
| **推送 tag** | `git tag bottle/<formula>/<version> && git push origin bottle/<formula>/<version>` |
| **手动触发** | GitHub Actions → Build bottle → Run workflow |

> 不自动触发分支推送，只响应 tag 和手动。

## 执行流程

```
推送 tag bottle/<formula>/<version>
          │
          ▼
┌─────────────────────────────┐
│ GitHub Actions 启动          │
│ runner: ubuntu-24.04-arm    │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│ DockerHarmony 容器           │
│ ┌─────────────────────────┐ │
│ │ 1. ci-runner/build.sh    │ │  初始化工具链、安装 Homebrew
│ │ 2. brew tap 本地工作区    │ │  挂载 workspace 为 local tap
│ │ 3. brew install          │ │  从源码编译（--build-bottle）
│ │    --build-bottle         │ │
│ │ 4. brew bottle --json    │ │  生成 .tar.gz + .json
│ │ 5. brew test             │ │  冒烟测试
│ │ 6. Python 合并 sha256    │ │  写回 Formula/<formula>.rb
│ └─────────────────────────┘ │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│ 上传到 GitHub Release        │
│ tag: bottles/<formula>      │
│ 资产: .tar.gz + .json       │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│ 提交并推送到 main 分支       │
│ commit: bottle: ..., push   │
└─────────────────────────────┘
```

## 配置说明

### workflow 环境变量
| 变量 | 说明 | 默认 |
|------|------|------|
| FORMULA | 配方名 | 必填 |
| SOFTWARE | 产物目录名 | 同 FORMULA |
| EXTRA_PACKAGES | 额外预装 formula | 空 |
| RUN_TESTS | 是否运行 brew test | true |

### 所需权限
- `contents: write` — 创建 Release、推送代码

### Docker 镜像
- `ghcr.io/hqzing/dockerharmony:latest` — 鸿蒙编译环境

## 重要文件

| 文件 | 作用 |
|------|------|
| `.github/workflows/bottle.yml` | CI 工作流定义 |
| `scripts/build-bottle.sh` | 容器内构建脚本 |
| `ci-runner/build.sh` | Docker 初始化（工具链、Homebrew） |
