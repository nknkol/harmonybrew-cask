#!/bin/sh
# 一次性修复 brew test / brew bottle / brew audit 的 gem 安装问题
#
# 两个根因：
# 1. /usr/bin/install 不存在（鸿蒙 PC 没有此路径）
# 2. Homebrew env -i PATH 过滤导致子进程找不到 cc
#
# 修复方法：
# 1. 修补 portable Ruby 的 rbconfig，将 INSTALL 指向实际路径
# 2. 在 shell 环境（PATH 正常）里预装所有 gem

set -e

RUBY_DIR=$(brew --prefix)/Homebrew/Library/Homebrew/vendor/portable-ruby/4.0.5
BUNDLE_DIR=$(brew --prefix)/Homebrew/Library/Homebrew/vendor/bundle/ruby/4.0.0
GEMLOCK=$(brew --prefix)/Homebrew/Library/Homebrew/Gemfile.lock
INSTALL_BIN=$(brew --prefix)/bin/install
RBCONFIG=$RUBY_DIR/lib/ruby/4.0.0/aarch64-linux-ohos/rbconfig.rb

echo "==> Step 1: Fix INSTALL path in portable Ruby..."
if ! grep -q "$INSTALL_BIN" "$RBCONFIG" 2>/dev/null; then
  cp "$RBCONFIG" "$RBCONFIG.bak" 2>/dev/null || true
  sed -i "s|/usr/bin/install|$INSTALL_BIN|g" "$RBCONFIG"
  echo "  rbconfig patched."
else
  echo "  already patched."
fi

echo "==> Step 2: Install all gems (this may take a while)..."

export GEM_HOME="$BUNDLE_DIR"
export GEM_PATH="$BUNDLE_DIR"

$RUBY_DIR/bin/ruby -e '
  lockfile = File.read("'"$GEMLOCK"'")
  in_specs = false
  lockfile.each_line do |line|
    if line =~ /^  specs:/
      in_specs = true; next
    elsif line =~ /^[^ ]/ && in_specs
      in_specs = false
    end
    next unless in_specs && line =~ /^\s{4}(\S+)\s+\(([^)]+)\)/
    name, ver = $1, $2
    puts "#{name}:#{ver}"
  end
' | while IFS=: read -r name ver; do
  $RUBY_DIR/bin/gem list -i "$name" -v "$ver" > /dev/null 2>&1 && continue
  printf "  %-30s" "$name $ver"
  if $RUBY_DIR/bin/gem install "$name" -v "$ver" -i "$BUNDLE_DIR" --no-document > /dev/null 2>&1; then
    echo "OK"
  else
    echo "FAIL (non-critical, may work at runtime)"
  fi
done

echo "==> Done."
