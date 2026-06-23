# Harmonybrew Cask

自定义 Homebrew tap，分发鸿蒙 (OpenHarmony) 平台的命令行软件包。

## 使用

```sh
brew tap nknkol/cask https://github.com/nknkol/harmonybrew-cask.git
brew install binary-sign-tool
```

## Formula 类型

| 类型 | 说明 | 签名方式 |
|------|------|----------|
| 源码编译 + 补丁 | 从源码编译（如 binary-sign-tool、rust） | 编译时 lld 自动签名 |
| 预编译开源软件 | 上游提供二进制，CI 签名后打包为 bottle | formula 依赖 `binary-sign-tool`，CI 签名 |
| 闭源软件 | 二进制来源不公开 | 同预编译 |

签名不再在 CI 脚本中处理，由 formula 自身声明 `depends_on "binary-sign-tool"` 并在 `post_install` 中调用。

## 多版本

每个大版本一个配方文件：

```
Formula/
├── binary-sign-tool.rb        ← 最新版
└── binary-sign-tool@1.0.rb    ← 固钉旧版
```

每个配方有独立的 `root_url` 和对应的 GitHub Release。

## 开发

### 新增/修改 formula

```sh
# 拉取 Docker 环境
docker pull ghcr.io/hqzing/dockerharmony:latest

# 进入容器
docker run -it --rm -v $(pwd):/workspace -w /workspace ghcr.io/hqzing/dockerharmony:latest

# 在容器内 tap 本地工作区
brew tap nknkol/cask /workspace

# 编辑 formula
vim Formula/xxx.rb

# 从源码构建验证
brew install -s -v --include-test nknkol/cask/<formula>

# 测试
brew test nknkol/cask/<formula>
```

### 构建 bottle

推送 tag 触发 CI：

```sh
git tag bottle/<formula>/<version>
git push origin bottle/<formula>/<version>
```

CI 自动：Docker 构建 → 签名 → 打包 → 上传 GitHub Release → formula 写回 main。

每个软件一个 Release（`bottles/<formula>`），升级版更新同一 Release。也可手动触发：GitHub Actions → Build bottle → Run workflow。

## 目录结构

```
├── Formula/              # Ruby 配方文件
├── patches/              # 源码补丁
├── scripts/
│   └── build-bottle.sh   # CI 瓶构建脚本
├── ci-runner/            # CI Docker 启动脚本
└── .github/workflows/
    └── bottle.yml         # CI 工作流（tag 触发 + 手动触发）
```
