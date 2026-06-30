class Libgcc < Formula
  desc "GCC runtime libraries for aarch64-unknown-linux-musl — libgcc, libstdc++, libatomic"
  homepage "https://gcc.gnu.org/"
  url "https://ftpmirror.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz"
  mirror "https://ftp.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz"
  sha256 "50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79"
  license "GPL-3.0-or-later" => { with: "GCC-exception-3.1" }

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Flibgcc"
  end

  # ---------------------------------------------------------------
  # 构建依赖
  # ---------------------------------------------------------------
  depends_on "bash" => :build
  depends_on "coreutils" => :build
  depends_on "gawk" => :build
  depends_on "grep" => :build
  depends_on "make" => :build

  # ---------------------------------------------------------------
  # 运行时 / 工具链依赖
  # ---------------------------------------------------------------
  depends_on "llvm@21"
  depends_on "ohos-sdk"

  # ---------------------------------------------------------------
  # GCC 构建前置依赖（GMP · MPFR · MPC · ISL）
  # 以 resource 形式内联到源码树中，由 GCC configure 自动探测，
  # 避免在 HarmonyOS 上额外维护外部 formula。
  # ---------------------------------------------------------------
  resource "gmp" do
    url "https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz"
    sha256 "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
  end

  resource "mpfr" do
    url "https://www.mpfr.org/mpfr-4.2.1/mpfr-4.2.1.tar.xz"
    sha256 "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2"
  end

  resource "mpc" do
    url "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
    sha256 "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8"
  end

  resource "isl" do
    url "https://libisl.sourceforge.io/isl-0.26.tar.xz"
    sha256 "a0b5cb06d24f9fa9e77b55fabbe9a3c94a336190345c2555f9915bb38e976504"
  end

  # ---------------------------------------------------------------
  # 目标三元组
  # ---------------------------------------------------------------
  def target
    "aarch64-unknown-linux-musl"
  end

  # ---------------------------------------------------------------
  # 构建
  # ---------------------------------------------------------------
  def install
    # ── 修复 TMPDIR（HarmonyOS 沙箱限制） ──────────────────────────
    ENV["TMPDIR"] = "/data/storage/el2/base/files/tmp"
    FileUtils.mkdir_p ENV["TMPDIR"]

    # ── 不依赖系统 Toybox 工具：强制使用 Homebrew 的 GNU 工具链 ──
    ohos_tools = %w[bash coreutils gawk grep make]
    ohos_tools.each do |t|
      ENV.prepend_path "PATH", Formula[t].opt_bin
      ENV.prepend_path "PATH", Formula[t].opt_libexec/"gnubin" if (Formula[t].opt_libexec/"gnubin").exist?
    end
    ENV["CONFIG_SHELL"] = Formula["bash"].opt_bin/"bash"
    ENV["AWK"] = Formula["gawk"].opt_bin/"awk"

    # ── 展开 resource 至 GCC 源码树顶层（configure 自动探测） ──────
    resource("gmp").stage(buildpath/"gmp")
    resource("mpfr").stage(buildpath/"mpfr")
    resource("mpc").stage(buildpath/"mpc")
    resource("isl").stage(buildpath/"isl")

    # ── 工具链路径 ─────────────────────────────────────────────────
    llvm       = Formula["llvm@21"]
    llvm_bin   = llvm.opt_bin
    ohos       = Formula["ohos-sdk"]
    sysroot    = ohos.opt_prefix/"native/sysroot"

    # ── 避免 GCC 将 cellar 路径写死到安装文件中 ─────────────────
    args = %W[
      --prefix=#{opt_prefix}
      --build=#{target}
      --host=#{target}
      --target=#{target}
      --with-sysroot=#{sysroot}
    ]

    # ── 构建编译器：使用 llvm@21 的 clang ─────────────────────────
    ENV["CC"]  = "#{llvm_bin}/clang"
    ENV["CXX"] = "#{llvm_bin}/clang++"

    # 指定汇编器 & 链接器：分别委派给 clang 的集成汇编器与 lld
    args << "--with-as=#{llvm_bin}/clang"
    args << "--with-ld=#{llvm_bin}/ld.lld"

    # ── 语言：仅 C / C++ ──────────────────────────────────────────
    args << "--enable-languages=c,c++"

    # ── 禁用的特性 ────────────────────────────────────────────────
    args += %W[
      --disable-bootstrap
      --disable-multilib
      --disable-nls
      --disable-libsanitizer
      --disable-libgomp
      --disable-libquadmath
      --disable-libssp
      --disable-libvtv
      --disable-libitm
      --disable-libstdcxx-pch
    ]

    # ── 主版本号目录（16 而非 16.1.0，便于 clang 查找） ────────
    args << "--with-gcc-major-version-only"

    # ── 同时生成静态库与共享库 ───────────────────────────────────
    args += %W[
      --enable-shared
      --enable-static
    ]

    # ── ELF build-id（与 HarmonyOS 生态一致） ─────────────────────
    args << "--enable-linker-build-id"

    # ── musl 不支持 GNU 符号版本化 ────────────────────────────────
    args << "--disable-symvers"

    # ── 修正 AArch64 multilib 的 lib64 → lib ─────────────────────
    inreplace "gcc/config/aarch64/t-aarch64-linux",
              "lp64=../lib64", "lp64="

    # ── 创建构建目录并执行三部曲 ────────────────────────────────
    mkdir "build" do
      system "../configure", *args

      # Step 1 · 构建编译器本体（cc1 / cc1plus / xgcc，不安装）
      system "gmake", "-j#{ENV.make_jobs}", "all-gcc"

      # Step 2 · 构建目标运行时库
      system "gmake", "-j#{ENV.make_jobs}", "all-target-libgcc"
      system "gmake", "-j#{ENV.make_jobs}", "all-target-libstdc++-v3"
      system "gmake", "-j#{ENV.make_jobs}", "all-target-libatomic"

      # Step 3 · 仅安装目标运行时库（编译器二进制不入包）
      system "gmake", "install-target-libgcc",
             "DESTDIR=#{Pathname.pwd}/../instdir"
      system "gmake", "install-target-libstdc++-v3",
             "DESTDIR=#{Pathname.pwd}/../instdir"
      system "gmake", "install-target-libatomic",
             "DESTDIR=#{Pathname.pwd}/../instdir"

      # 移入实际 prefix（配合 --prefix=#{opt_prefix} 避免路径固化）
      mv Dir[Pathname.pwd/"../instdir/#{opt_prefix}/*"], prefix
    end

    # ── 便捷符号链接 ──────────────────────────────────────────────
    target_dir = prefix/target
    gcc_dir    = lib/"gcc"/target/version.major.to_s

    # C++ 头文件 → #{include}/c++/
    cxx_include = target_dir/"include/c++"
    if cxx_include.exist?
      (include/"c++").install_symlink cxx_include.children
    end

    # 目标 .a / .so → #{lib}/
    target_lib = target_dir/"lib"
    if target_lib.exist?
      target_lib.children.each { |f| lib.install_symlink f }
    end

    # gcc 运行时（crtbegin.o / libgcc.a / libgcc_s.so …） → #{lib}/
    if gcc_dir.exist?
      gcc_dir.children.each { |f| lib.install_symlink f }
    end
  end

  # ---------------------------------------------------------------
  # 冒烟测试
  # ---------------------------------------------------------------
  test do
    ohos_sysroot = Formula["ohos-sdk"].opt_prefix/"native/sysroot"
    clangxx      = Formula["llvm@21"].opt_bin/"clang++"

    (testpath/"hello.cpp").write <<~CPP
      #include <iostream>
      #include <atomic>
      int main() {
        std::atomic<int> x{42};
        std::cout << "Hello libgcc: " << x.load() << std::endl;
        return 0;
      }
    CPP

    # 用现有 Clang 编译 → 链接我们提供的 libstdc++ / libgcc / libatomic
    system clangxx.to_s,
      "-target", target,
      "--sysroot=#{ohos_sysroot}",
      "-L#{lib}",
      "-Wl,-rpath,#{lib}",
      "-I#{include}/c++/#{version.major}",
      "-I#{include}/c++/#{version.major}/#{target}",
      "-o", "hello",
      "hello.cpp"

    assert_equal "Hello libgcc: 42\n", shell_output("./hello")
  end
end
