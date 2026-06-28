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
#   TAP_URL        — tap 仓库 URL，默认 https://github.com/nknkol/harmonybrew-cask.git
#   EXTRA_PACKAGES — 额外预装 formula（空格分隔）

set -eu

IMAGE="${IMAGE:-ohosci:1.0}"
CONTAINER="${CONTAINER:-ohosci-builder}"
TAP="${TAP:-nknkol/cask}"
TAP_URL="${TAP_URL:-https://github.com/nknkol/harmonybrew-cask.git}"

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

container_exec() {
  docker exec -i "$CONTAINER" /bin/sh -lc "$1"
}

formula_depends_on_cmake() {
  container_exec "
    set -eu
    export PATH=/storage/Users/currentUser/.harmonybrew/bin:\$PATH
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_INSTALL_FROM_API=1
    brew deps --include-build '$QUALIFIED' 2>/dev/null | grep -qx cmake
  "
}

repair_cmake_compiler_id_detection() {
  docker exec -i "$CONTAINER" /bin/sh -c 'cat >/tmp/repair-cmake-compiler-id.sh && /bin/sh /tmp/repair-cmake-compiler-id.sh' <<'EOS'
set -eu

export PATH=/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.harmonybrew/sbin:$PATH

if ! command -v cmake >/dev/null 2>&1; then
  exit 0
fi

cmake_root="$(cmake --system-information 2>/dev/null | sed -n 's/^CMAKE_ROOT "\([^"]*\)"/\1/p' | head -n 1)"
if [ -z "$cmake_root" ] || [ ! -f "$cmake_root/Modules/CMakeCompilerIdDetection.cmake" ]; then
  exit 0
fi

module="$cmake_root/Modules/CMakeCompilerIdDetection.cmake"
external_project_module="$cmake_root/Modules/ExternalProject/shared_internal_commands.cmake"

if grep -q "Harmonybrew local-build: avoid CMake file(GLOB)" "$module"; then
  compiler_id_fixed=1
else
  compiler_id_fixed=0
fi

smoke_dir="/tmp/cmake-compiler-id-smoke"
rm -rf "$smoke_dir"
mkdir -p "$smoke_dir"
cat >"$smoke_dir/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(smoke C CXX)
CMAKE

if [ "$compiler_id_fixed" -eq 0 ] &&
   cmake -S "$smoke_dir" -B "$smoke_dir/build" 2>&1 | grep -q "compiler identification is unknown"; then
  tmp="${module}.tmp"
  awk '
    BEGIN { replaced_lang = 0; replaced_nonlang = 0; skip = 0 }
    skip > 0 { skip--; next }
    !replaced_lang && $0 ~ /^[[:space:]]*file\(GLOB lang_files[[:space:]]*$/ {
      print "    # Harmonybrew local-build: avoid CMake file(GLOB) on OHOS overlay dirs."
      print "    execute_process("
      print "      COMMAND /bin/find \"${CMAKE_ROOT}/Modules/Compiler\" -maxdepth 1 -type f -name \"*-DetermineCompiler.cmake\""
      print "      OUTPUT_VARIABLE lang_files"
      print "      OUTPUT_STRIP_TRAILING_WHITESPACE)"
      print "    if (lang_files)"
      print "      string(REPLACE \"\\n\" \";\" lang_files \"${lang_files}\")"
      print "    endif()"
      replaced_lang = 1
      skip = 1
      next
    }
    !replaced_nonlang && $0 ~ /^[[:space:]]*file\(GLOB nonlang_files[[:space:]]*$/ {
      print "    execute_process("
      print "      COMMAND /bin/find \"${CMAKE_ROOT}/Modules/Compiler\" -maxdepth 1 -type f -name \"*-${nonlang}-DetermineCompiler.cmake\""
      print "      OUTPUT_VARIABLE nonlang_files"
      print "      OUTPUT_STRIP_TRAILING_WHITESPACE)"
      print "    if (nonlang_files)"
      print "      string(REPLACE \"\\n\" \";\" nonlang_files \"${nonlang_files}\")"
      print "    endif()"
      replaced_nonlang = 1
      skip = 1
      next
    }
    { print }
    END {
      if (!replaced_lang || !replaced_nonlang) {
        exit 42
      }
    }
  ' "$module" >"$tmp"
  mv "$tmp" "$module"
fi

rm -rf "$smoke_dir"

if [ -f "$external_project_module" ] &&
   ! grep -q "Harmonybrew local-build: avoid CMake file(GLOB) for ExternalProject" "$external_project_module"; then
  tmp="${external_project_module}.tmp"
  awk '
    BEGIN { replaced = 0; in_func = 0 }
    !replaced && $0 ~ /^function\(_ep_is_dir_empty dir empty_var\)/ {
      print "function(_ep_is_dir_empty dir empty_var)"
      print "  # Harmonybrew local-build: avoid CMake file(GLOB) for ExternalProject."
      print "  if(NOT IS_DIRECTORY \"${dir}\")"
      print "    set(${empty_var} 1 PARENT_SCOPE)"
      print "    return()"
      print "  endif()"
      print "  execute_process("
      print "    COMMAND /bin/find \"${dir}\" -mindepth 1 -maxdepth 1 -print -quit"
      print "    OUTPUT_VARIABLE _ep_first_entry"
      print "    OUTPUT_STRIP_TRAILING_WHITESPACE)"
      print "  if(\"${_ep_first_entry}\" STREQUAL \"\")"
      print "    set(${empty_var} 1 PARENT_SCOPE)"
      print "  else()"
      print "    set(${empty_var} 0 PARENT_SCOPE)"
      print "  endif()"
      print "endfunction()"
      replaced = 1
      in_func = 1
      next
    }
    in_func {
      if ($0 ~ /^endfunction\(\)/) {
        in_func = 0
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        exit 42
      }
    }
  ' "$external_project_module" >"$tmp"
  mv "$tmp" "$external_project_module"
fi
EOS
}

# ── 重建镜像（无需 formula） ──────────────────────────────────
if $REBUILD; then
  echo "==> Rebuilding image: $IMAGE"
  (cd ci-runner && DOCKER_BUILDKIT=0 docker build --no-cache -t "$IMAGE" .)
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "==> Removing old container so it uses rebuilt image: $CONTAINER"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
fi

# ── 确保容器运行 ──────────────────────────────────────────────
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
    echo "==> Starting: $CONTAINER"
    if ! docker start "$CONTAINER" >/dev/null; then
      echo "==> Recreating unhealthy container: $CONTAINER"
      docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
      docker run -d --name "$CONTAINER" "$IMAGE" /bin/sh -c 'while true; do sleep 3600; done'
    fi
  fi
else
  echo "==> Creating: $CONTAINER"
  docker run -d --name "$CONTAINER" "$IMAGE" /bin/sh -c 'while true; do sleep 3600; done'
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
  echo "  TAP_URL          tap repo URL (default: https://github.com/nknkol/harmonybrew-cask.git)"
  echo "  EXTRA_PACKAGES   extra formula to pre-install"
  exit 1
fi

# ── 构建全流程 ────────────────────────────────────────────────
QUALIFIED="$TAP/$FORMULA"

if $FRESH; then
  echo "==> Uninstalling old version…"
  docker exec -i "$CONTAINER" /bin/sh -lc "
    export PATH=/storage/Users/currentUser/.harmonybrew/bin:\$PATH
    brew uninstall --ignore-dependencies --force '$QUALIFIED' 2>/dev/null || true
  "
fi

echo "==> [1/5] Sync tap…"
if $NO_SYNC; then
  echo "  (skipped)"
else
  docker exec -i "$CONTAINER" /bin/sh -lc "
    set -eu
    export PATH=/storage/Users/currentUser/.harmonybrew/bin:\$PATH
    export HOMEBREW_NO_AUTO_UPDATE=1
    if ! brew tap | grep -q '^$TAP\$'; then
      echo '==> Adding tap $TAP …'
      brew tap --force '$TAP' '$TAP_URL'
    fi
    brew update
  "
fi

if formula_depends_on_cmake; then
  echo "==> Preparing CMake for local container…"
  container_exec "
    set -eu
    export PATH=/storage/Users/currentUser/.harmonybrew/bin:\$PATH
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_INSTALL_FROM_API=1
    brew install cmake
  "
  repair_cmake_compiler_id_detection
fi

echo "==> [2/5] Pre-requisites…"
if [ -n "$EXTRA_PACKAGES" ]; then
  container_exec "
    set -eu
    export PATH=/storage/Users/currentUser/.harmonybrew/bin:\$PATH
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
  export PATH=/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.harmonybrew/sbin:\$PATH
  export HOMEBREW_NO_AUTO_UPDATE=1
  export HOMEBREW_NO_INSTALL_FROM_API=1
  export HOMEBREW_NO_INSTALL_CLEANUP=1
  export HOMEBREW_NO_ENV_HINTS=1

  brew install --verbose --build-bottle '$QUALIFIED'
"

echo "==> [4/5] brew bottle --skip-relocation $QUALIFIED …"
docker exec -i "$CONTAINER" /bin/sh -lc "
  set -eu
  export PATH=/storage/Users/currentUser/.harmonybrew/bin:\$PATH
  export HOMEBREW_NO_AUTO_UPDATE=1
  export HOMEBREW_NO_INSTALL_FROM_API=1

  cd /tmp
  brew bottle --verbose --skip-relocation --json '$QUALIFIED'
"

if [ "$RUN_TESTS" -eq 1 ]; then
  echo "==> [5/5] brew test $QUALIFIED …"
  docker exec -i "$CONTAINER" /bin/sh -lc "
    set -eu
    export PATH=/storage/Users/currentUser/.harmonybrew/bin:\$PATH
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
