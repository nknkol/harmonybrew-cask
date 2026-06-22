class BinarySignTool < Formula
  desc "OpenHarmony ELF binary signing tool"
  homepage "https://gitee.com/openharmony/developtools_hapsigner"
  url "https://github.com/openharmony/developtools_hapsigner/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
  sha256 "5f1b8f6cb40443d5f80f2f394334fcc5a7da2f8ab0e50159608f58b885f9213d"
  license "Apache-2.0"
  version "1.0.0"

  depends_on "openssl@3"
  depends_on "zlib-ng-compat"
  depends_on "make" => :build

  patch do
    # Adds compat.h and Makefile for standalone compilation
    # without the full OpenHarmony GN build system
    file "patches/binary-sign-tool/0001-standalone-build.patch"
  end

  # ELFIO — C++ header-only library for ELF parsing
  resource "elfio" do
    url "https://github.com/openharmony/third_party_elfio/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "<TODO>"
  end

  # nlohmann/json — C++ JSON library (header-only)
  resource "nlohmann-json" do
    url "https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz"
    sha256 "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d"
  end

  # bounds_checking_function — OpenHarmony secure C functions
  resource "bounds_checking_function" do
    url "https://github.com/openharmony/third_party_bounds_checking_function/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "3b4500e94df63f475733c6dcaeb9a5efe67e955938392bfa3bcb5471ed78b296"
  end

  def install
    # ── Unpack third-party resources into expected paths ──────────
    (buildpath/"third_party").mkpath
    (buildpath/"third_party/third_party_elfio").install resource("elfio")
    (buildpath/"third_party/third_party_json").install resource("nlohmann-json")
    (buildpath/"third_party/third_party_bounds_checking_function").install resource("bounds_checking_function")

    # ── Build ─────────────────────────────────────────────────────
    openssl_prefix = Formula["openssl@3"].opt_prefix

    system "make",
           "CXX=clang++",
           "CXXFLAGS=-std=c++17 -fno-rtti -target aarch64-linux-ohos",
           "OPENSSL_PREFIX=#{openssl_prefix}",
           "PROJ=#{buildpath}",
           "-j#{ENV.make_jobs}"

    # ── Install ───────────────────────────────────────────────────
    bin.install "build/binary-sign-tool" => "binary-sign-tool-fix"
  end

  test do
    system "#{bin}/binary-sign-tool-fix"
  end
end
