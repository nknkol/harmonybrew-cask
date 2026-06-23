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

    # ── Apply patches ─────────────────────────────────────────────
    # Use explicit patch commands to avoid Homebrew's patch DSL
    # which fails on harmless offset hunks in 0002.
    tap_root = Pathname.new(__FILE__).dirname.parent
    patch1 = tap_root/"patches/binary-sign-tool/0001-standalone-build.patch"
    patch2 = tap_root/"patches/binary-sign-tool/0002-fix-elf-signing.patch"

    cd buildpath do
      system "patch", "-p1", "-i", patch1.to_s
      # 0002 may exit 1 on offset hunks that still apply correctly
      ohai "Applying 0002-fix-elf-signing.patch"
      safe_system "patch -f -p1 -i #{patch2} || [ $? -le 1 ]"
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
