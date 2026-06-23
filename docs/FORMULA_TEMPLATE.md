# Formula 配方样板

## 源码编译（binary-sign-tool 类型）

```ruby
class BinarySignTool < Formula
  desc "OpenHarmony ELF binary signing tool"
  homepage "https://gitee.com/openharmony/developtools_hapsigner"
  url "https://github.com/openharmony/developtools_hapsigner/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
  sha256 "<fill-in-with-brew-fetch>"
  license "Apache-2.0"
  version "1.0.0"

  # 必填：瓶子下载地址（每个软件一个稳定 Release）
  bottle do
    root_url "https://github.com/<user>/<repo>/releases/download/bottles%2F<formula>"
  end

  # 编译依赖
  depends_on "cmake" => :build
  depends_on "make" => :build
  depends_on "gpatch" => :build   # 需要打补丁时
  depends_on "openssl@3"

  # 运行时依赖
  depends_on "zlib-ng-compat"

  # 补丁（从官方源打）—— 把补丁放在 patches/<formula>/ 下
  patch do
    file "patches/binary-sign-tool/0001-fix-elf-signing.patch"
  end

  # 第三方依赖（没有 Homebrew formula 的）
  resource "elfio" do
    url "https://github.com/openharmony/third_party_elfio/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "<fill-in>"
  end

  def install
    ENV.deparallelize  # 鸿蒙 tmpfs 不支持并行 jobserver

    # 解压 resource 到指定目录
    (buildpath/"third_party/third_party_elfio").install resource("elfio")

    # 编译
    system "make",
           "CXX=clang++",
           "CXXFLAGS=-std=c++17 -fno-rtti -target aarch64-linux-ohos",
           "OPENSSL_PREFIX=#{Formula["openssl@3"].opt_prefix}",
           "PROJ=#{buildpath}"

    bin.install "build/<binary-name>"
  end

  test do
    system "#{bin}/<binary-name>"
  end
end
```

## 预编译二进制（reasonix / starship 类型）

```ruby
class Reasonix < Formula
  desc "DeepSeek Reasonix"
  homepage "https://github.com/esengine/DeepSeek-Reasonix"
  version "1.10.0"
  url "https://github.com/esengine/DeepSeek-Reasonix/releases/download/v#{version}/reasonix-linux-arm64.tar.gz"
  sha256 "<fill-in>"

  bottle do
    root_url "https://github.com/<user>/<repo>/releases/download/bottles%2Freasonix"
  end

  # 需要签名
  depends_on "binary-sign-tool"

  def install
    bin.install "reasonix"
    chmod 0755, bin/"reasonix"
  end

  def post_install
    # 签名由 formula 自身处理，不在 CI 脚本中
    system "binary-sign-tool-fix", "sign",
           "-inFile", bin/"reasonix",
           "-outFile", bin/"reasonix",
           "-selfSign", "1"
  end

  test do
    system "#{bin}/reasonix", "--version"
  end
end
```

## 多版本固钉

```ruby
# Formula/binary-sign-tool.rb      — 最新版
# Formula/binary-sign-tool@1.0.rb  — 旧版固钉
# 每个配方独立的 root_url
```
