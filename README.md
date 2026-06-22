# Harmonybrew Cask

自定义 Homebrew tap，分发鸿蒙 (OpenHarmony) 平台的命令行软件包。

## 使用

```sh
brew tap nknkol/cask https://github.com/nknkol/harmonybrew-cask.git
brew install binary-sign-tool
```

## Formula 类型

| 类型 | 说明 | 签名需求 |
|------|------|----------|
| 预编译开源软件 | 上游提供二进制，CI 签名后打包为 bottle | 是 |
| 闭源软件 | 二进制来源不公开，CI 签名后打包 | 是 |
| 源码编译 + 补丁 | 从源码编译，编译时签名（lld） | 否 |

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

推送 tag 触发 CI 自动构建：

```sh
git tag bottle/<formula>/<version>
git push origin bottle/<formula>/<version>
```

CI 完成后：bottle 上传到 GitHub Release，formula 自动更新 bottle block 并推回 main。

也可以手动触发：GitHub Actions → Build bottle → Run workflow。

## 目录结构

```
├── Formula/          # Ruby 配方文件
├── patches/          # 源码补丁
├── scripts/
│   ├── build-bottle.sh    # CI 通用瓶构建脚本
│   └── sign-elf.sh        # ELF 签名工具
└── .github/workflows/
    └── bottle.yml     # CI 工作流
```
