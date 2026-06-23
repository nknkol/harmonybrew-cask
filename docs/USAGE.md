# 仓库使用说明

## 安装软件

```zsh
# 添加 tap
brew tap nknkol/cask https://github.com/nknkol/harmonybrew-cask.git

# 安装
brew install binary-sign-tool

# 从源码安装（跳过 bottle）
brew install -s nknkol/cask/binary-sign-tool
```

## 目录结构

```
├── Formula/              # Ruby 配方文件
│   ├── binary-sign-tool.rb
│   └── ...
├── patches/              # 源码补丁（每个 formula 一个子目录）
│   └── binary-sign-tool/
│       └── 0001-fix-elf-signing.patch
├── scripts/
│   └── build-bottle.sh   # CI 瓶构建脚本
├── ci-runner/            # Docker CI 启动脚本
│   └── build.sh
├── docs/                 # 文档
│   ├── FORMULA_TEMPLATE.md   # 配方样板
│   ├── FORMULA_SPEC.md       # 配方规范
│   ├── CI_FLOW.md            # CI 流程
│   └── USAGE.md              # 本文件
└── .github/workflows/
    └── bottle.yml         # CI 工作流
```

## 开发流程

### 新增软件

1. Fork 本仓库
2. 编写 formula（参考 `docs/FORMULA_TEMPLATE.md`）
3. 制作补丁（参考 `docs/FORMULA_SPEC.md`）
4. 在 DockerHarmony 容器中验证：
   ```zsh
   docker pull ghcr.io/hqzing/dockerharmony:latest
   docker run -it --rm -v $(pwd):/workspace -w /workspace ghcr.io/hqzing/dockerharmony:latest
   brew tap nknkol/cask /workspace
   brew install -s -v --include-test nknkol/cask/<formula>
   ```
5. 提交 PR，等待合并
6. 合并后推 tag 触发 CI 构建 bottle：
   ```zsh
   git tag bottle/<formula>/<version>
   git push origin bottle/<formula>/<version>
   ```

### 更新软件

1. 修改 formula 的 `url`、`sha256`、`version`
2. 提交并推 tag 触发 CI

### 手动触发 CI

GitHub Actions → Build bottle → Run workflow，填写 formula 名称。

## Bottle 发布策略

- 每个 formula 一个 Release：`bottles/<formula>`
- 升级版本时 CI 自动覆盖同一个 Release
- 多版本（`<formula>@1.0`）使用独立的 Release
- Release 由 CI 自动管理，无需手动操作
