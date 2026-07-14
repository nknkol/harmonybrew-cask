#!/bin/sh

ORIG_SRC="${ORIG_SRC:-$HOME/bun/bun-bun-v1.3.14}"
BUILD_SRC="${BUILD_SRC:-$HOME/bun-bun-v1.3.14}"
BASE="${BASE:-https://raw.githubusercontent.com/nknkol/harmonybrew-cask/main/patches/bun}"

PATCHES="
0001-fix-platform-syscalls.patch
0002-fix-resolver-traversal.patch
0003-fix-hmdfs-filesystem.patch
0004-fix-harmonyos-path-permissions.patch
0005-debug-cache-resolver.patch
"

FILES="
src/bundler/bundle_v2.zig
src/bundler/linker.zig
src/node-fallbacks/build-fallbacks.ts
src/jsc/bindings/c-bindings.cpp
src/resolver/resolver.zig
src/cli/create_command.zig
src/install/PackageInstall.zig
src/install/isolated_install/Installer.zig
src/install/npm.zig
src/resolver/fs.zig
src/cli/run_command.zig
src/install/PackageManager.zig
"

fail() {
  echo "error: $*" >&2
  return 1
}

main() {
  if [ ! -d "$ORIG_SRC" ]; then
    fail "original source directory not found: $ORIG_SRC"
    return 1
  fi

  if [ ! -d "$BUILD_SRC" ]; then
    fail "build source directory not found: $BUILD_SRC"
    return 1
  fi

  tmp_patch="$BUILD_SRC/.bun-bootstrap-patch.$$"
  trap 'rm -f "$tmp_patch"' EXIT HUP INT TERM

  echo "resetting patched source files"
  echo "  from: $ORIG_SRC"
  echo "    to: $BUILD_SRC"

  for file in $FILES; do
    src="$ORIG_SRC/$file"
    dst="$BUILD_SRC/$file"

    if [ ! -f "$src" ]; then
      fail "missing original file: $src"
      return 1
    fi

    mkdir -p "$(dirname "$dst")" || return 1
    cp -p "$src" "$dst" || return 1
    echo "  reset $file"
  done

  echo "applying patches from $BASE"
  for patch in $PATCHES; do
    echo "  apply $patch"
    curl -fsSL "$BASE/$patch" -o "$tmp_patch" || return 1
    if command -v git >/dev/null 2>&1; then
      git -C "$BUILD_SRC" apply "$tmp_patch" || return 1
    else
      (cd "$BUILD_SRC" && patch -p1 < "$tmp_patch") || return 1
    fi
  done

  rm -f "$tmp_patch"
  trap - EXIT HUP INT TERM
  echo "done"
  return 0
}

main "$@"
