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

  patch do
    # Fixes ELFIO::save() corrupting ELF layout during signing.
    # Replaces the ELFIO-based section append with a raw-byte
    # approach that preserves original Program Headers, section
    # offsets, and inter-segment padding.  Also migrates cJSON
    # to nlohmann/json (already used elsewhere in the tree).
    file "patches/binary-sign-tool/0002-fix-elf-signing.patch"
  end

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
    # ── Remove files deleted by the 0002 ELF signing patch ────────
    # The patch removes Java build artifacts and unused C++ files
    # that are not needed for standalone C++ compilation.
    rm_f buildpath/"binary_sign_tool/common/include/password_guard.h"
    rm_f buildpath/"binary_sign_tool/common/include/signature_tools_log.h"
    rm_f buildpath/"binary_sign_tool/java/pom.xml"
    rm_f buildpath/"binary_sign_tool/java/settings.xml"
    rm_f buildpath/"binary_sign_tool/java/binary_sign_tool/pom.xml"
    rm_f buildpath/"binary_sign_tool/java/binary_sign_tool/src/main/resources/help.txt"
    rm_f buildpath/"binary_sign_tool/java/binary_sign_tool/src/main/resources/log.properties"
    rm_f buildpath/"binary_sign_tool/java/binary_sign_tool_lib/pom.xml"
    rm_f buildpath/"binary_sign_tool/java/binary_sign_tool_lib/src/test/resources/log.properties"
    rm_f buildpath/"binary_sign_tool/java/elfio/pom.xml"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/ArraySectionAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/DynamicSectionAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/ElfHeader.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/ElfTypes.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/Elfio.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/ElfioDump.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/ElfioUtils.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/ModInfoSectionAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/NoteSectionAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/RelocationSectionAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/Section.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/Segment.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/StringSectionAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/SymbolSectionAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/VersionDefinitionAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/VersionNeedAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/VersionSymbolAccessor.java"
    rm_f buildpath/"binary_sign_tool/java/elfio/src/main/java/com/ohos/elfio/ZlibCompression.java"
    rm_f buildpath/"binary_sign_tool/utils/include/compare_elf.h"
    rm_f buildpath/"binary_sign_tool/utils/src/compare_elf.cpp"
    rm_f buildpath/"hapsigntool_cpp/common/include/password_guard.h"
    rm_f buildpath/"hapsigntool_cpp/common/src/password_guard.cpp"

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
