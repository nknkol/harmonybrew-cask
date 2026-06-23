# Formula 配方样板

## 1. 源码编译

```ruby
class BinarySignTool < Formula
  desc "OpenHarmony ELF binary signing tool"
  homepage "https://gitee.com/openharmony/developtools_hapsigner"
  url "https://github.com/openharmony/developtools_hapsigner/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
  sha256 "<fill-in-with-brew-fetch>"
  license "Apache-2.0"
  version "1.0.0"

  bottle do
    root_url "https://github.com/<user>/<repo>/releases/download/bottles%2F<formula>"
  end

  depends_on "cmake" => :build
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

    bin.install "build/<binary>"
  end

  test do
    system "#{bin}/<binary>"
  end
end
```

## 2. 预编译 / 闭源软件

```ruby
class SomeTool < Formula
  desc "某预编译/闭源工具"
  homepage "https://example.com"
  url "https://example.com/releases/tool-arm64.tar.gz"
  sha256 "<fill-in>"
  version "1.0.0"

  bottle do
    root_url "https://github.com/<user>/<repo>/releases/download/bottles%2Fsome-tool"
  end

  def install
    bin.install "tool"
  end

  def post_install
    # 本地签名：二进制必须先签名才能在鸿蒙运行
    system "binary-sign-tool-fix", "sign",
           "-inFile", bin/"tool",
           "-outFile", bin/"tool",
           "-selfSign", "1"
  end

  test do
    system "#{bin}/tool", "--version"
  end
end
```

## 3. 多版本固钉

```ruby
# Formula/xxx.rb          ← 最新版
# Formula/xxx@1.0.rb      ← 旧版固钉

# xxx@1.0.rb:
class XxxAT10 < Formula
  ...
  bottle do
    root_url ".../releases/download/bottles%2Fxxx%401.0"
  end
  ...
end
```
