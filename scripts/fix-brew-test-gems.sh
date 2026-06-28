#!/bin/sh
# 在 brew test 之前预装带 C 扩展的 gem（绕过 Homebrew 的 env -i PATH 过滤）
# 
# Homebrew 子进程找不到 cc（PATH 只含 /usr/bin:/bin），但普通 shell 可以。
# 此脚本在 shell 环境里预编译好 gem，brew test 发现有缓存就跳过编译。
#
# 鸿蒙 PC 缺少 /usr/bin/install，make install 会失败。extconf.rb 和 make 能过，
# build 产物 prism.so 已生成，手工完成安装步骤即可。

set -e

RUBY_DIR=$(brew --prefix)/Homebrew/Library/Homebrew/vendor/portable-ruby/4.0.3_1
BUNDLE_DIR=$(brew --prefix)/Homebrew/Library/Homebrew/vendor/bundle/ruby/4.0.0
EXT_DIR=$BUNDLE_DIR/extensions/aarch64-linux-ohos/4.0.0-static/prism-1.9.0
GEM_DIR=$BUNDLE_DIR/gems/prism-1.9.0

echo "==> Installing prism (C extension gem)..."

# 清理旧残留
rm -rf "$EXT_DIR" "$GEM_DIR"
rm -f  "$BUNDLE_DIR/specifications/prism-1.9.0"* "$BUNDLE_DIR/specifications/prism-1.9.0"*.gemspec

# 1. extconf.rb + make（这步在 shell 环境能过）
cd /tmp
$RUBY_DIR/bin/gem unpack prism -v 1.9.0 --target="$BUNDLE_DIR/gems" > /dev/null 2>&1 || true
cd "$GEM_DIR/ext/prism" 2>/dev/null && $RUBY_DIR/bin/ruby extconf.rb > /dev/null 2>&1 && make -j$(nproc) > /dev/null 2>&1
echo "   extconf.rb + make: ok"

# 2. 手动安装 prism.so（绕过 /usr/bin/install）
mkdir -p "$EXT_DIR"
cp "$GEM_DIR/ext/prism/prism.so" "$EXT_DIR/"

# 3. 标记 build 完成（bundle check 会检查这个文件）
echo "extconf.rb: ok" > "$EXT_DIR/gem.build_complete"
echo "make: ok" >> "$EXT_DIR/gem.build_complete"

# 4. 写入 gemspec（bundle check 检查规格文件）
mkdir -p "$BUNDLE_DIR/specifications"
$RUBY_DIR/bin/ruby -e "
  require 'rubygems'
  spec = Gem::Specification.load('$GEM_DIR/prism.gemspec')
  spec.extension_dir = '$EXT_DIR'
  File.write('$BUNDLE_DIR/specifications/prism-1.9.0.gemspec', spec.to_ruby)
"

echo "==> Done. Run: brew test <formula>"
