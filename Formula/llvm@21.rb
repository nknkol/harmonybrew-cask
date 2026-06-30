class LlvmAT21 < Formula
  desc "LLVM 21.1.8 toolchain for HarmonyOS — clang, lld, compiler-rt"
  homepage "https://llvm.org"
  url "https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-21.1.8.zip"
  sha256 "2b2aae18bdba34ba8ee8249ad42ad3cb56f932f4142070c6eb920966f7c5905f"
  license "Apache-2.0"
  keg_only "conflicts with ohos-sdk; use brew link llvm@21 to activate"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fllvm@21"
      sha256 cellar: :any_skip_relocation, arm64_ohos: "bb099bbe4770eb2170e58c58444c36c8dc6069748a270aa3bb097fcb73ab7e33"
  end

  depends_on "cmake" => :build
  depends_on "ninja" => :build
  depends_on "gpatch" => :build
  depends_on "python" => :build
  depends_on "uname-is-linux" => :build

  depends_on "ohos-sdk"
  depends_on "zlib"
  depends_on "libxml2"
  depends_on "libedit"

  # ---------------------------------------------------------------
  # 补丁
  # ---------------------------------------------------------------
  def apply_patches
    tap_root = Pathname.new(__FILE__).dirname.parent
    patch_file = tap_root/"patches/llvm@21/0001-add-ohos-codesign-lts.patch"
    cd buildpath do
      system "patch", "-f", "-p1", "-i", patch_file.to_s
    end
  end

  # ---------------------------------------------------------------
  # 构建
  # ---------------------------------------------------------------
  def install
    ENV["LD_PRELOAD"] =
      Formula["uname-is-linux"].opt_lib/"libuname.so"
    ENV["TMPDIR"] = "/data/storage/el2/base/files/tmp"
    FileUtils.mkdir_p ENV["TMPDIR"]

    apply_patches

    ohos = Formula["ohos-sdk"].opt_prefix/"native"
    ohos_sysroot = ohos/"sysroot"
    ohos_llvm_lib = ohos/"llvm/lib/aarch64-linux-ohos"
    zlib_root = Formula["zlib"].opt_prefix

    system "cmake", "-S", "llvm", "-B", "build", "-G", "Ninja",
      "-DCMAKE_INSTALL_PREFIX=#{prefix}",
      "-DCMAKE_SYSTEM_NAME=Linux",
      "-DCMAKE_BUILD_TYPE=Release",
      "-DCMAKE_CXX_FLAGS=-stdlib=libc++",
      "-DCMAKE_EXE_LINKER_FLAGS=-lc++ -Wl,--code-sign",
      "-DCMAKE_SHARED_LINKER_FLAGS=-lc++ -Wl,--code-sign",
      "-DCMAKE_MODULE_LINKER_FLAGS=-lc++ -Wl,--code-sign",
      "-DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-ohos",
      "-DDEFAULT_SYSROOT=#{ohos_sysroot}",
      "-DCLANG_DEFAULT_RTLIB=compiler-rt",
      "-DCLANG_DEFAULT_UNWINDLIB=libunwind",
      "-DCLANG_DEFAULT_CXX_STDLIB=libc++",
      "-DLLVM_INSTALL_UTILS=ON",
      "-DCLANG_DEFAULT_LINKER=lld",
      "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib",
      "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON",
      "-DLLVM_ENABLE_LIBPFM=OFF",
      "-DLLVM_TARGETS_TO_BUILD=AArch64;X86",
      "-DLLVM_ENABLE_PROJECTS=clang;lld",
      "-DLLVM_ENABLE_RUNTIMES=compiler-rt",
      "-DCOMPILER_RT_BUILD_SANITIZERS=OFF",
      "-DCOMPILER_RT_BUILD_XRAY=OFF",
      "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF",
      "-DCOMPILER_RT_BUILD_MEMPROF=OFF",
      "-DCOMPILER_RT_BUILD_ORC=OFF",
      "-DZLIB_ROOT=#{zlib_root}"

    system "ninja", "-C", "build"
    system "cmake", "--install", "build", "--prefix", prefix

    clang_runtime_lib = lib/"clang/#{version.major}/lib"
    default_runtime_dir = clang_runtime_lib/"aarch64-unknown-linux-ohos"
    ohos_runtime_dir = clang_runtime_lib/"aarch64-linux-ohos"
    ln_s default_runtime_dir.basename, ohos_runtime_dir unless ohos_runtime_dir.exist?

    ohos_llvm_lib.glob("libunwind.*").each do |f|
      ln_s f, lib/f.basename
      ln_s f, default_runtime_dir/f.basename
    end
    ohos_llvm_lib.glob("libc++*").each do |f|
      ln_s f, lib/f.basename
      ln_s f, default_runtime_dir/f.basename
    end

  end

  def caveats
    <<~EOS
      llvm@21 is keg-only to avoid conflicting with ohos-sdk.

      To switch to this toolchain:
        brew unlink ohos-sdk && brew link llvm@21

      To switch back:
        brew unlink llvm@21 && brew link ohos-sdk

      Verify the active compiler:
        which clang
    EOS
  end

  test do
    ohos_sysroot = Formula["ohos-sdk"].opt_prefix/"native/sysroot"
    (testpath/"hello.c").write <<~C
      #include <stdio.h>
      int main() { printf("hello\\n"); return 0; }
    C
    system bin/"clang", "--sysroot=#{ohos_sysroot}", "-c", "hello.c", "-o", "hello.o"
  end
end
