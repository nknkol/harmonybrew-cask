class LlvmAT21 < Formula
  desc "LLVM 21.1.8 toolchain for HarmonyOS — clang, lld, compiler-rt"
  homepage "https://llvm.org"
  url "https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-21.1.8.zip"
  sha256 "2b2aae18bdba34ba8ee8249ad42ad3cb56f932f4142070c6eb920966f7c5905f"
  license "Apache-2.0"
  keg_only "conflicts with ohos-sdk; use brew link llvm@21 to activate"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fllvm@21"
        sha256 cellar: :any_skip_relocation, arm64_ohos: "e37d2b411047bacc23f613108db2a4095bb621871b348c8e476323a138b99a54"
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

    # cmake --install skips compiler-rt runtimes. Install them manually.
    build_runtime_lib = buildpath/"build/lib/clang"/version.major/"lib"/"aarch64-unknown-linux-ohos"
    target_runtime_lib = lib/"clang"/version.major/"lib"/"aarch64-unknown-linux-ohos"
    target_runtime_lib.mkpath
    build_runtime_lib.each_child { |f| cp f, target_runtime_lib/f.basename }

    # Copy crt objects from libgcc into the runtime dir (not in sysroot).
    libgcc_lib = Formula["libgcc"].opt_lib
    %w[crtbeginS.o crtendS.o crtbegin.o crtend.o].each do |crt|
      cp libgcc_lib/crt, target_runtime_lib/crt
    end

    # Symlink for clang's runtime dir lookup (some paths use aarch64-linux-ohos).
    ohos_runtime_dir = lib/"clang"/version.major/"lib"/"aarch64-linux-ohos"
    ln_s target_runtime_lib.basename, ohos_runtime_dir unless ohos_runtime_dir.exist?

    # Stage 2: build libcxx + libcxxabi using the just-installed clang.
    # (Runtime bootstrapping with HOMEBREW_CC/CXX causes header mismatch.)
    ENV.delete "CC"
    ENV.delete "CXX"
    ohos_llvm_lib = ohos/"llvm/lib/aarch64-linux-ohos"
    runtime_ldflags = "-L#{Formula["libgcc"].opt_lib} " \
                       "-L#{ohos_llvm_lib} " \
                       "-lc++ -Wl,--code-sign"
    system "cmake", "-S", "runtimes", "-B", "build-runtimes", "-G", "Ninja",
      "-DCMAKE_INSTALL_PREFIX=#{prefix}",
      "-DCMAKE_C_COMPILER=#{prefix}/bin/clang",
      "-DCMAKE_CXX_COMPILER=#{prefix}/bin/clang++",
      "-DCMAKE_CXX_FLAGS=-stdlib=libc++",
      "-DCMAKE_EXE_LINKER_FLAGS=#{runtime_ldflags}",
      "-DCMAKE_SHARED_LINKER_FLAGS=#{runtime_ldflags}",
      "-DCMAKE_MODULE_LINKER_FLAGS=#{runtime_ldflags}",
      "-DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-ohos",
      "-DLLVM_ENABLE_RUNTIMES=libcxx;libcxxabi",
      "-DLIBCXXABI_USE_LLVM_UNWINDER=OFF",
      "-DLIBCXXABI_ENABLE_SHARED=OFF",
      "-DLIBCXX_ENABLE_SHARED=OFF",
      "-DLIBCXX_PROVIDES_DEFAULT_RUNE_TABLE=ON",
      "-DDEFAULT_SYSROOT=#{ohos_sysroot}",
      "-DCMAKE_C_COMPILER_TARGET=aarch64-unknown-linux-ohos",
      "-DCMAKE_CXX_COMPILER_TARGET=aarch64-unknown-linux-ohos",
      "-DCMAKE_C_FLAGS=--sysroot=#{ohos_sysroot}",
      "-DCMAKE_CXX_FLAGS=--sysroot=#{ohos_sysroot} -stdlib=libc++ -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE",
      "-DCMAKE_SYSROOT=#{ohos_sysroot}"
    # cmake sets _LIBCPP_HAS_MUSL_LIBC=0 in __config_site despite our flag.
    # Force it to 1 so musl code paths (no _l locale functions) are used.
    inreplace buildpath/"build-runtimes/include/c++/v1/__config_site",
              "#define _LIBCPP_HAS_MUSL_LIBC 0",
              "#define _LIBCPP_HAS_MUSL_LIBC 1"
    system "ninja", "-C", "build-runtimes", "install"

    # Symlink libc++ to runtime dir so the linker finds them.
    # Also create clang++.cfg so clang finds C++ headers.
    runtime_dir = lib/"clang"/version.major/"lib"/"aarch64-unknown-linux-ohos"
    %w[libc++.a libc++abi.a libc++experimental.a].each do |libname|
      ln_s lib/libname, runtime_dir/libname unless (runtime_dir/libname).exist?
    end
    %w[libunwind.a libunwind.so].each do |libname|
      src = ohos/"llvm/lib/aarch64-linux-ohos"/libname
      ln_s src, lib/libname if src.exist? && !(lib/libname).exist?
      ln_s src, runtime_dir/libname if src.exist? && !(runtime_dir/libname).exist?
    end
    File.write(bin/"clang++.cfg", "-cxx-isystem#{include}/c++/v1\n")
    File.write(bin/"clang.cfg",   "-isystem#{include}\n")

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
