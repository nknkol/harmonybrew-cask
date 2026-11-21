# Formula 配方样板 / Formula Templates

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

> [!NOTE]
> 以下样板适用于本**个人自用** Harmonybrew Tap（`nknkol/cask`）。

## 1. 预编译 / 闭源 Linux ARM64 软件（推荐：`elf-patch-loader`）

适用于需要运行在 `nknkol/cask/glibc` 或需要内存补丁 / `TRAP_SIGSYS` 拦截的软件（参考 `Formula/antigravity.rb`、`Formula/bun.rb`、`Formula/claude-code.rb`、`Formula/codex.rb`）：

```ruby
class SomeTool < Formula
  desc "Example prebuilt or closed-source CLI"
  homepage "https://example.com"
  url "https://example.com/releases/tool-1.0.0-linux-arm64.tar.gz"
  sha256 "<fill-in>"
  version "1.0.0"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fsome-tool"
  end

  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "nknkol/cask/glibc" # 若上游为静态 musl 二进制则省略此行

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def install
    tap_root = Pathname.new(__FILE__).dirname.parent
    system RbConfig.ruby, (tap_root/"patches/elf-patch-loader/install_loader.rb").to_s,
           "--binary", (buildpath/"tool").to_s,
           "--config", (tap_root/"patches/some-tool/tool.elfpatch").to_s,
           "--prefix", prefix.to_s,
           "--name", "tool",
           "--glibc-lib", Formula["nknkol/cask/glibc"].opt_lib.to_s,
           "--sign-tool", sign_tool.to_s
  end

  test do
    verify_out = shell_output("ELFPATCH_VERIFY=1 #{bin}/tool 2>&1")
    assert_match "verification passed", verify_out
    assert_match version.to_s, shell_output("#{bin}/tool --version")
  end
end
```

配套的 `patches/some-tool/tool.elfpatch` 最小示例：

```text
PROGRAM @PROGRAM@
INTERP  @GLIBC_INTERP@
RUNPATH @GLIBC_LIB@
TRAP_SIGSYS
```

## 2. 源码编译 + 补丁

```ruby
class BinarySignTool < Formula
  desc "OpenHarmony ELF binary signing tool"
  homepage "https://gitee.com/openharmony/developtools_hapsigner"
  url "https://github.com/openharmony/developtools_hapsigner/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
  sha256 "<fill-in-with-brew-fetch>"
  license "Apache-2.0"
  version "1.0.0"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fbinary-sign-tool"
  end

  depends_on "make" => :build
  depends_on "gpatch" => :build
  depends_on "openssl@3"
  depends_on "zlib-ng-compat"

  patch do
    file "patches/binary-sign-tool/0001-fix-elf-signing.patch"
  end

  resource "elfio" do
    url "https://github.com/openharmony/third_party_elfio/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "<fill-in>"
  end

  def install
    ENV.deparallelize
    (buildpath/"third_party/third_party_elfio").install resource("elfio")

    system "make",
           "CXX=clang++",
           "CXXFLAGS=-std=c++17 -fno-rtti -target aarch64-linux-ohos",
           "OPENSSL_PREFIX=#{Formula["openssl@3"].opt_prefix}",
           "PROJ=#{buildpath}"

    bin.install "build/binary-sign-tool-fix"
  end

  test do
    system "#{bin}/binary-sign-tool-fix", "--help"
  end
end
```

## 3. 历史版本化固钉配方（`<name>@<version>.rb`）

```ruby
# Formula/some-tool.rb       ← 最新版
# Formula/some-tool@1.0.rb   ← 历史版本归档

class SomeToolAT10 < Formula
  desc "Example CLI (archived 1.0)"
  homepage "https://example.com"
  url "https://example.com/releases/tool-1.0.0-linux-arm64.tar.gz"
  sha256 "<fill-in>"
  version "1.0.0"
  keg_only :versioned_formula

  # 注意：不要保留指向主配方瓶子的 bottle do 块，避免按 @version 命名请求时 404
  ...
end
```

## 4. 附录：源码补丁制作方法

1. 将官方源码包解压两份至 `a/` 与 `b/`，在 `b/` 中完成适配修改。
2. 生成标准 unified diff 补丁：
   ```sh
   diff -ruN a b > 0001-add-ohos-support.patch
   ```
3. 放入小写 **`patches/<formula>/`** 目录，并在 Formula 中通过 `patch do` 引用：
   ```ruby
   patch do
     file "patches/<formula>/0001-add-ohos-support.patch"
   end
   ```

---

<a id="english"></a>

> [!NOTE]
> Templates for this **personal** Harmonybrew tap (`nknkol/cask`).

## 1. Prebuilt / Closed-Source Linux ARM64 Binary (Preferred: `elf-patch-loader`)

```ruby
class SomeTool < Formula
  desc "Example prebuilt or closed-source CLI"
  homepage "https://example.com"
  url "https://example.com/releases/tool-1.0.0-linux-arm64.tar.gz"
  sha256 "<fill-in>"
  version "1.0.0"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fsome-tool"
  end

  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "nknkol/cask/glibc" # Omit for static musl binaries

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def install
    tap_root = Pathname.new(__FILE__).dirname.parent
    system RbConfig.ruby, (tap_root/"patches/elf-patch-loader/install_loader.rb").to_s,
           "--binary", (buildpath/"tool").to_s,
           "--config", (tap_root/"patches/some-tool/tool.elfpatch").to_s,
           "--prefix", prefix.to_s,
           "--name", "tool",
           "--glibc-lib", Formula["nknkol/cask/glibc"].opt_lib.to_s,
           "--sign-tool", sign_tool.to_s
  end

  test do
    verify_out = shell_output("ELFPATCH_VERIFY=1 #{bin}/tool 2>&1")
    assert_match "verification passed", verify_out
    assert_match version.to_s, shell_output("#{bin}/tool --version")
  end
end
```

Minimal `patches/some-tool/tool.elfpatch`:

```text
PROGRAM @PROGRAM@
INTERP  @GLIBC_INTERP@
RUNPATH @GLIBC_LIB@
TRAP_SIGSYS
```

## 2. Source-Built Formula with Patches

Place patches under lowercase **`patches/<formula>/`** (not uppercase `Patches/`) and reference them with `patch do` (`file "patches/<formula>/0001-xxx.patch"`). See the Chinese section above for a complete example.

## 3. Archived Versioned Formula (`<name>@<version>.rb`)

Always declare `keg_only :versioned_formula` and omit the primary formula's `bottle do` block so Homebrew does not request a non-existent `<name>@<version>--<version>` bottle tarball.
