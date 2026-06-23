class BinarySignTool < Formula
  desc "OpenHarmony ELF binary signing tool"
  homepage "https://gitee.com/openharmony/developtools_hapsigner"
  url "https://github.com/openharmony/developtools_hapsigner/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
  sha256 "59d5858c2224ac93daa4b619d022e07dabde861ce715931d4a35f034ce746fb9"
  license "Apache-2.0"
  version "1.0.0"
  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fbinary-sign-tool"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "160915de090403fea0b91f5aa5de2c7b2a5e3b26caad9584bd8ad814f8d3a826"
  end

  depends_on "openssl@3"
  depends_on "zlib-ng-compat"
  depends_on "make" => :build
  depends_on "gpatch" => :build

  # ELFIO — C++ header-only library for ELF parsing
  resource "elfio" do
    url "https://github.com/openharmony/third_party_elfio/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "efaf64750081b10300430da5c4b1720758da02719f8d82c4f747962c29fda18b"
  end

  # nlohmann/json — C++ JSON library (header-only, replaces cJSON)
  resource "nlohmann-json" do
    url "https://github.com/openharmony/third_party_json/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "65d17c4ce65f48f79c233a959805e9cc8b3bcda90adeabe2721d4b3ec3d859c5"
  end

  # bounds_checking_function — OpenHarmony secure C functions
  resource "bounds_checking_function" do
    url "https://github.com/openharmony/third_party_bounds_checking_function/archive/refs/tags/OpenHarmony-v7.0-Beta1.tar.gz"
    sha256 "3b4500e94df63f475733c6dcaeb9a5efe67e955938392bfa3bcb5471ed78b296"
  end

  def install
    ENV.deparallelize

    # Apply patch (Homebrew's DSL fails on offset hunks)
    tap_root = Pathname.new(__FILE__).dirname.parent
    patch_file = tap_root/"patches/binary-sign-tool/0001-fix-elf-signing.patch"
    cd buildpath do
      system "patch -f -p1 -i #{patch_file} || [ $? -le 1 ]"
    end

    # ── Unpack third-party resources into expected paths ──────────
    (buildpath/"third_party").mkpath
    (buildpath/"third_party/third_party_elfio").install resource("elfio")
    (buildpath/"third_party/third_party_json").install resource("nlohmann-json")
    (buildpath/"third_party/third_party_bounds_checking_function").install resource("bounds_checking_function")

    # ── Build ─────────────────────────────────────────────────────
    openssl_prefix = Formula["openssl@3"].opt_prefix

    cd buildpath do
      system "make",
             "CXX=clang++",
             "CXXFLAGS=-std=c++17 -fno-rtti -target aarch64-linux-ohos",
             "OPENSSL_PREFIX=#{openssl_prefix}",
             "PROJ=#{buildpath}"
    end

    # ── Install ───────────────────────────────────────────────────
    bin.install "build/binary-sign-tool" => "binary-sign-tool-fix"
  end

  test do
    system "#{bin}/binary-sign-tool-fix"
  end
end
