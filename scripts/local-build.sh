#!/bin/bash
# local-build.sh — 本地完整跑瓶子创建流程，复用镜像节省时间
#
# 用法:
#   sh scripts/local-build.sh <formula>              # 完整流程
#   sh scripts/local-build.sh <formula> --no-test    # 跳过 brew test
#   sh scripts/local-build.sh <formula> --fresh      # 先卸载旧版本
#   sh scripts/local-build.sh <formula> --no-sync    # 跳过 brew update
#   sh scripts/local-build.sh <formula> --shell      # 只进容器
#   sh scripts/local-build.sh <formula> --rebuild    # 先重建镜像
#
# 环境变量（可选）:
#   IMAGE          — 镜像名，默认 ohosci:1.0
#   CONTAINER      — 容器名，默认 ohosci-builder
#   TAP            — tap 全名，默认 nknkol/cask
#   EXTRA_PACKAGES — 额外预装 formula（空格分隔）

set -eu

IMAGE="${IMAGE:-ohosci:1.0}"
CONTAINER="${CONTAINER:-ohosci-builder}"
TAP="${TAP:-nknkol/cask}"

FORMULA="${1:-}"

if [ -n "$FORMULA" ]; then
  shift
else
  FORMULA=""
fi

NO_TEST=false
FRESH=false
SHELL_ONLY=false
REBUILD=false
PULL=false
NO_SYNC=false

while [ $# -gt 0 ]; do
  case "$1" in
    --no-test)  NO_TEST=true; shift ;;
    --fresh)    FRESH=true; shift ;;
    --shell)    SHELL_ONLY=true; shift ;;
    --rebuild)  REBUILD=true; shift ;;
    --pull)     PULL=true; shift ;;
    --no-sync)  NO_SYNC=true; shift ;;
    --software) SOFTWARE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SOFTWARE="${SOFTWARE:-$FORMULA}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
RUN_TESTS=0; $NO_TEST || RUN_TESTS=1

# ── 重建镜像（无需 formula） ──────────────────────────────────
if $REBUILD; then
  echo "==> Rebuilding image: $IMAGE"
  DOCKER_BUILDKIT=0 docker build --no-cache -t "$IMAGE" -f ci-runner/Dockerfile .
fi

# ── 确保容器运行 ──────────────────────────────────────────────
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
    echo "==> Starting: $CONTAINER"
    docker start "$CONTAINER" >/dev/null
  fi
else
  echo "==> Creating: $CONTAINER"
  docker run -d --name "$CONTAINER" "$IMAGE" tail -f /dev/null
fi

# ── 只进 shell（无需 formula） ────────────────────────────────
if $SHELL_ONLY; then
  echo "==> Entering container…"
  docker exec -it "$CONTAINER" /bin/sh -lc '
    export PATH="/storage/Users/currentUser/.harmonybrew/bin:$PATH"
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_INSTALL_FROM_API=1
    exec /bin/sh
  '
  exit 0
fi

# ── 没有指定包名则到此为止 ────────────────────────────────────
if [ -z "$FORMULA" ]; then
  echo "Usage: sh scripts/local-build.sh [<formula>] [options]"
  echo ""
  echo "  <formula>   package to build (optional; skip to just ensure container)"
  echo ""
  echo "Options:"
  echo "  --no-test      skip brew test"
  echo "  --fresh        uninstall old version first"
  echo "  --shell        enter container shell only"
  echo "  --no-sync      skip brew update before building"
  echo "  --rebuild      rebuild image before running"
  echo "  --pull         copy artifacts to ./artifacts/"
  echo "  --software <n> artifact dir name (default: same as formula)"
  echo ""
  echo "Env vars (optional):"
  echo "  IMAGE            image name (default: ohosci:1.0)"
  echo "  CONTAINER        container name (default: ohosci-builder)"
  echo "  TAP              tap name (default: nknkol/cask)"
  echo "  EXTRA_PACKAGES   extra formula to pre-install"
  exit 1
fi

# ── 构建全流程 ────────────────────────────────────────────────
QUALIFIED="$TAP/$FORMULA"

if $FRESH; then
  echo "==> Uninstalling old version…"
  docker exec -i "$CONTAINER" /bin/sh -lc "
    export PATH='/storage/Users/currentUser/.harmonybrew/bin:\$PATH'
    brew uninstall --ignore-dependencies --force '$QUALIFIED' 2>/dev/null || true
  "
fi

echo "==> [1/5] Sync tap…"
if $NO_SYNC; then
  echo "  (skipped)"
else
  docker exec -i "$CONTAINER" /bin/sh -lc "
    set -eu
    export PATH='/storage/Users/currentUser/.harmonybrew/bin:\$PATH'
    export HOMEBREW_NO_AUTO_UPDATE=1
    brew update
  "
fi

echo "==> [2/5] Pre-requisites…"
if [ -n "$EXTRA_PACKAGES" ]; then
  docker exec -i "$CONTAINER" /bin/sh -lc "
    set -eu
    export PATH='/storage/Users/currentUser/.harmonybrew/bin:\$PATH'
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_INSTALL_FROM_API=1
    for pkg in $EXTRA_PACKAGES; do
      brew install --verbose '$TAP/'\"\$pkg\"
    done
  "
else
  echo "  (none)"
fi

echo "==> [3/5] brew install --build-bottle $QUALIFIED …"
docker exec -i "$CONTAINER" /bin/sh -lc "
  set -eu
  export PATH='/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.harmonybrew/sbin:\$PATH'
  export HOMEBREW_NO_AUTO_UPDATE=1
  export HOMEBREW_NO_INSTALL_FROM_API=1
  export HOMEBREW_NO_INSTALL_CLEANUP=1
  export HOMEBREW_NO_ENV_HINTS=1

  brew install --verbose --build-bottle '$QUALIFIED'
"

echo "==> [4/5] brew bottle --skip-relocation $QUALIFIED …"
docker exec -i "$CONTAINER" /bin/sh -lc "
  set -eu
  export PATH='/storage/Users/currentUser/.harmonybrew/bin:\$PATH'
  export HOMEBREW_NO_AUTO_UPDATE=1
  export HOMEBREW_NO_INSTALL_FROM_API=1

  cd /tmp
  brew bottle --verbose --skip-relocation --json '$QUALIFIED'
"

if [ "$RUN_TESTS" -eq 1 ]; then
  echo "==> [5/5] brew test $QUALIFIED …"
  docker exec -i "$CONTAINER" /bin/sh -lc "
    set -eu
    export PATH='/storage/Users/currentUser/.harmonybrew/bin:\$PATH'
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_INSTALL_FROM_API=1
    export HOMEBREW_OHOS_BOTTLE_BINARY_SIGN=1

    brew postinstall '$QUALIFIED'
    brew test --verbose '$QUALIFIED'
  "
else
  echo "==> [5/5] brew test (skipped)"
fi

# ── 拉取产物（可选） ───────────────────────────────────────────
if $PULL; then
  echo "==> Pulling artifacts…"
  rm -rf "./artifacts/$SOFTWARE"
  docker cp "$CONTAINER:/tmp/$FORMULA-"*.tar.gz "./artifacts/$SOFTWARE/" 2>/dev/null || true
  docker cp "$CONTAINER:/tmp/$FORMULA-"*.json    "./artifacts/$SOFTWARE/" 2>/dev/null || true
  echo ""
  echo "Artifacts: ./artifacts/$SOFTWARE/"
  ls -lh "./artifacts/$SOFTWARE/" 2>/dev/null || echo "  (none)"
fi

echo "Container '$CONTAINER' kept. Cleanup: docker rm -f $CONTAINER"
