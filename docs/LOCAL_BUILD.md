# 本地构建

`scripts/local-build.sh` 在本地（或远端 Docker 环境）完整复现 CI 的瓶子创建流程，用于开发阶段验证 formula 能否通过编译、生成瓶子、通过测试。

与 CI 的区别：不写 git、不上传 Release，只跑核心的 install → bottle → test 三步。

## 为什么用这个脚本

| 痛点 | 解决方式 |
|------|---------|
| 每次 CI 跑全流程太慢 | 本地先验证通过再推 tag |
| `docker run --rm` 每次都销毁容器 | 容器常驻复用，省去重复初始化 |
| 远端环境不能 `-v` bind mount | 不挂载，直接用 tap 里已同步的 formula |

## 前置条件

```bash
# 1. 构建镜像（只需一次）
DOCKER_BUILDKIT=0 docker build --no-cache -t ohosci:1.0 -f ci-runner/Dockerfile .

# 2. 确保 tap 已同步（在容器内）
docker run -d --name ohosci-builder ohosci:1.0 tail -f /dev/null
docker exec -it ohosci-builder /bin/sh -lc '
  export PATH="/storage/Users/currentUser/.harmonybrew/bin:$PATH"
  brew tap --force nknkol/cask https://github.com/nknkol/harmonybrew-cask.git
'
```

之后容器一直保留，无需重复创建。

## 用法

```bash
# 构建指定包（全流程：install → bottle → test）
sh scripts/local-build.sh <formula>

# 跳过测试
sh scripts/local-build.sh <formula> --no-test

# 先卸载旧版本再构建
sh scripts/local-build.sh <formula> --fresh

# 拉取产物到 ./artifacts/
sh scripts/local-build.sh <formula> --pull

# 覆盖产物目录名（默认同 formula）
sh scripts/local-build.sh <formula> --software my-tool --pull

# 镜像有改动时重建
sh scripts/local-build.sh <formula> --rebuild

# 只进容器交互调试
sh scripts/local-build.sh <formula> --shell

# 不指定包名，只确保容器运行
sh scripts/local-build.sh
```

## 选项

| 选项 | 作用 |
|------|------|
| `--no-test` | 跳过 `brew test` |
| `--fresh` | 先 `brew uninstall` 再安装 |
| `--shell` | 不构建，只进入容器 shell |
| `--rebuild` | 重新 `docker build` 镜像 |
| `--pull` | 把 `.tar.gz` / `.json` 拉到 `./artifacts/` |
| `--software <n>` | 产物子目录名（默认同 formula） |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `IMAGE` | `ohosci:1.0` | 镜像名 |
| `CONTAINER` | `ohosci-builder` | 容器名 |
| `TAP` | `nknkol/cask` | tap 全名 |
| `EXTRA_PACKAGES` | 空 | 额外预装的 formula（空格分隔） |

## 执行步骤（对照 CI）

| 步骤 | 本地 | CI |
|------|------|----|
| 初始化工具链 | ❌ 镜像已内置 | ✅ `ci-runner/build.sh` |
| 预装依赖 | ✅ `[1/4]` | ✅ `EXTRA_PACKAGES` |
| 源码安装 | ✅ `[2/4] brew install --build-bottle` | ✅ |
| 生成瓶子 | ✅ `[3/4] brew bottle --json` | ✅ |
| 冒烟测试 | ✅ `[4/4] brew test` | ✅ |
| 合并 sha256 到 formula | ❌ | ✅ |
| 上传 Release | ❌ | ✅ |
| git commit / push | ❌ | ✅ |

## 典型工作流

```bash
# 1. 开发 formula，在容器里手动试错
sh scripts/local-build.sh my-package --shell
# 在容器内：brew install -s nknkol/cask/my-package … 反复调试

# 2. 本地跑全流程验证
sh scripts/local-build.sh my-package

# 3. 通过后，提交并推 tag 触发 CI
git add Formula/my-package.rb
git commit -m "Add my-package formula"
git push origin main
git tag bottles/my-package
git push origin bottles/my-package
```

## 清理

```bash
docker rm -f ohosci-builder      # 销毁容器
docker rmi ohosci:1.0            # 删除镜像（如需重建）
```
