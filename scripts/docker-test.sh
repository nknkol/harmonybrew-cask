#!/bin/sh
# 本地 brew test 的平替方案——在 DockerHarmony 容器中运行
# 
# Homebrew 启动时通过 env -i 过滤环境，PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin。
# 鸿蒙 PC 系统分区只读，无法将 cc 放入这些路径，因此本地 brew test 不可行。
# 
# 此脚本在 Docker 容器中运行测试，与 CI 流程一致。

set -e

FORMULA="${1:-}"
if [ -z "$FORMULA" ]; then
  echo "Usage: sh scripts/docker-test.sh <formula>"
  echo "Example: sh scripts/docker-test.sh llvm@21"
  exit 1
fi

echo "==> Running brew test for $FORMULA in DockerHarmony..."
docker run --rm \
  -v "$(brew --prefix)/..:/storage/Users/currentUser/.harmonybrew" \
  -v "$(pwd):/workspace" \
  -w /workspace \
  ghcr.io/hqzing/dockerharmony:latest \
  /bin/sh -c "
    sh ci-runner/build.sh
    export PATH=/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.harmonybrew/sbin:\$PATH
    brew test nknkol/cask/$FORMULA
  "
