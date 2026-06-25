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

## 4 附录：补丁制作指南

### 4.1 准备源码

下载源码包，将源码包解压两次，得到两份干净的源码。这里假设源码目录名字分别为 a 和 b。


### 4.2 制作补丁

修改目录 b 中的源码，对其进行业务适配。适配完成后，需制作标准补丁文件。推荐做法如下：

```sh
# -r: 递归目录; -u: 统一格式; -N: 处理缺失文件;
diff -ruN a b > 0001-add-ohos-support.patch
```

### 4.3 引入补丁

在仓库的 `Patches` 目录下创建一个与 formula 同名的子目录，将补丁放置其中。示例：`Patches/perl/0001-add-ohos-support.patch`

然后在本地 formula 中加入 `patch` 块，指向补丁文件：

```rb
  patch do
    file "Patches/perl/0001-add-ohos-support.patch"
  end
```

### 4.3 验证补丁

执行 `brew install -s -v --include-test <formula>`、`brew test <formula>` 验证构建和测试是否通过。如果不通过，需要重新制作补丁、重新验证，直至验证通过。

> 该做法每次都会对软件包进行全量构建。虽耗时长，但操作简单，适用于大多数场景和用户。对于需要调试大型软件包、有增量构建需求的用户，可自行寻找其他方法进行增量构建，提高自身调试效率。

