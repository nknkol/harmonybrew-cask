class Hapsigntool < Formula
  desc "OpenHarmony HAP/HSP/HQF signing tool with HNP code-signing support"
  homepage "https://gitee.com/openharmony/developtools_hapsigner"
  url "https://github.com/openharmony/developtools_hapsigner/archive/35c282cfcd09fd31e9d6c90013793459f1fdea92.tar.gz"
  sha256 "0b8462e1e2f4d64750f2a9aa14ad74e6cfe9afec3403fb659bb04d083046d3f9"
  license "Apache-2.0"
  version "1.0.0"

  depends_on "zlib-ng-compat"
  depends_on "make" => :build
  depends_on "gpatch" => :build
  depends_on "perl" => :build

  resource "openssl" do
    url "https://www.openssl.org/source/openssl-1.1.1w.tar.gz"
    sha256 "cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"
  end

  resource "cjson" do
    url "https://github.com/openharmony/third_party_cJSON/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "6ef947c705441da11bc0a733cde685eea23a2a155f6b2f22cf3b50d64428a55a"
  end

  resource "zlib" do
    url "https://github.com/openharmony/third_party_zlib/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "460afdfb94df2cd2d92e2372d5d154940874f771b57827f7eca65c428a8ff3a4"
  end

  resource "bounds_checking_function" do
    url "https://github.com/openharmony/third_party_bounds_checking_function/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "3b4500e94df63f475733c6dcaeb9a5efe67e955938392bfa3bcb5471ed78b296"
  end

  def install
    ENV.deparallelize

    tap_root = Pathname.new(__FILE__).dirname.parent

    patch1 = tap_root/"patches/hapsigntool/0001-add-hnp-signing.patch"
    cd buildpath do
      system "patch -f -p0 -i #{patch1} || [ $? -le 1 ]"
    end

    patch2 = tap_root/"patches/hapsigntool/0002-add-standalone-makefile.patch"
    cd buildpath do
      system "patch -f -p1 -i #{patch2} || [ $? -le 1 ]"
    end

    (buildpath/"third_party").mkpath
    (buildpath/"third_party/openssl").install resource("openssl")
    (buildpath/"third_party/third_party_cJSON").install resource("cjson")
    (buildpath/"third_party/third_party_zlib").install resource("zlib")
    (buildpath/"third_party/third_party_bounds_checking_function").install resource("bounds_checking_function")

    zlib_prefix = Formula["zlib-ng-compat"].opt_prefix

    cd buildpath do
      system "make",
             "CXX=clang++",
             "CXXFLAGS=-std=c++17 -fno-rtti -target aarch64-linux-ohos",
             "ZLIB_PREFIX=#{zlib_prefix}",
             "AR_PATH=#{HOMEBREW_PREFIX}/bin/llvm-ar",
             "PROJ=#{buildpath}"
    end

    bin.install "build/hap-sign-tool" => "hap-sign-tool-fix"
  end

  test do
    system "#{bin}/hap-sign-tool-fix"
  end
end
