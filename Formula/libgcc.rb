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
  depends_on "gawk" => :build
  depends_on "gnu-sed" => :build
  depends_on "grep" => :build
  depends_on "make" => :build

  # ---------------------------------------------------------------
  # 运行时 / 工具链依赖
  # ---------------------------------------------------------------
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

    # ── 修复 config.status 的 umask 077 subshell 权限问题 ──────────
    # HarmonyOS hmdfs 不支持 chmod，只能靠创建时的 umask 控制权限。
    # config.status 中 (umask 077 && mktemp -d ...) 导致目录无 group/other
    # 写权限。提供 wrapper 在调用真实 mktemp 前先 umask 000 覆盖。
    mktemp_wrapper = buildpath/"mktemp"
    mktemp_wrapper.atomic_write <<~SH
      #!/bin/sh
      umask 000
      exec /bin/mktemp "$@"
    SH
    mktemp_wrapper.chmod 0755
    ENV.prepend_path "PATH", buildpath

    # ── 不依赖系统 Toybox 工具：通过 autoconf 环境变量精确指定 ──
    # 注意：不能 prepend coreutils 到 PATH（GNU cat 在管道中断时
    # 会向 stderr 打印 "Broken pipe"，触发 configure 的 set -e 致死）
    ENV["CONFIG_SHELL"] = Formula["bash"].opt_bin/"bash"
    ENV["AWK"]          = Formula["gawk"].opt_bin/"awk"
    ENV["GREP"]         = Formula["grep"].opt_bin/"grep"
    ENV["SED"]          = Formula["gnu-sed"].opt_bin/"sed"
    # 仅 make 需要 prepend（configure 通过 MAKE 变量不一定生效）
    ENV.prepend_path "PATH", Formula["make"].opt_bin

    # ── 展开 resource 至 GCC 源码树顶层（configure 自动探测） ──────
    resource("gmp").stage(buildpath/"gmp")
    resource("mpfr").stage(buildpath/"mpfr")
    resource("mpc").stage(buildpath/"mpc")
    resource("isl").stage(buildpath/"isl")

    # ── 工具链路径：使用 ohos-sdk 的 clang（libc++ 头文件完备） ──
    ohos       = Formula["ohos-sdk"]
    ohos_llvm  = ohos.opt_prefix/"native/llvm"
    ohos_bin   = ohos_llvm/"bin"
    sysroot    = ohos.opt_prefix/"native/sysroot"

    # GCC 的 --with-as 路径被编译进 xgcc 二进制，不走任何 wrapper。
    # clang 作为汇编器需要 -c 标志来停在汇编阶段（否则会继续链接）。
    # 创建一个始终带 -c 的 wrapper，让 configure 将它当作"汇编器"。
    clang_as = buildpath/"clang-as"
    clang_as.atomic_write <<~SH
      #!/bin/sh
      exec "#{ohos_bin}/clang" -c "$@"
    SH
    clang_as.chmod 0755

    # ── sysroot 是 aarch64-linux-ohos，但 GCC 只认 linux-musl ──
    # 创建相对符号链接，让 GCC 在 musl 路径下找到 ohos 的 bits/ 和 lib/
    %w[usr/include usr/lib].each do |sub|
      target_dir = sysroot/sub/ "aarch64-unknown-linux-musl"
      ohos_dir   = sysroot/sub/ "aarch64-linux-ohos"
      unless target_dir.exist?
        ln_s "aarch64-linux-ohos", target_dir
      end
    end

    # ── autoconf 头文件检测修复 ──────────────────────────────────
    # -Wl,--code-sign 在预处理阶段（-E）产生 stderr 警告，
    # ac_fn_c_try_cpp 发现 stderr 非空即判失败 → HAVE_FCNTL_H=no
    # ① 从 CC/CXX 移除 --code-sign，仅保留在 LDFLAGS
    # ② ac_cv_header_* 直接告诉 configure 跳过检测
    ENV["CC"]       = "#{ohos_bin}/clang   --sysroot=#{sysroot}"
    ENV["CXX"]      = "#{ohos_bin}/clang++ --sysroot=#{sysroot}"
    ENV["CFLAGS"]   = "--sysroot=#{sysroot}"
    ENV["CXXFLAGS"] = "--sysroot=#{sysroot}"
    ENV["LDFLAGS"]  = "--sysroot=#{sysroot} -Wl,--code-sign"
    ENV["ac_cv_header_fcntl_h"] = "yes"
    ENV["ac_cv_header_limits_h"] = "yes"
    ENV["ac_cv_header_spawn_h"] = "yes"
    ENV["ac_cv_header_unistd_h"] = "yes"
    # ISL 的 configure 检测到 clang 不报 undeclared builtin 后
    # 会全局加 -fno-builtin，导致后续 ffs/__builtin_ffs 检测全挂。
    ENV["ac_cv_c_undeclared_builtin_options"] = "none needed"
    # ISL 的 ffs 检测不含 <strings.h>，clang-15 不支持
    # (void) __builtin_ffs 取地址。直接告诉 ISL ffs 可用。
    ENV["ac_cv_have_decl_ffs"] = "yes"

    # ── 避免 GCC 将 cellar 路径写死到安装文件中 ─────────────────
    args = %W[
      --prefix=#{opt_prefix}
      --build=#{target}
      --host=#{target}
      --target=#{target}
      --with-sysroot=#{sysroot}
      --with-build-sysroot=#{sysroot}
      --enable-host-pie
    ]

    # 汇编器 & 链接器 & 归档工具同样走 ohos-sdk
    args << "--with-as=#{clang_as}"
    args << "--with-ld=#{ohos_bin}/ld.lld"
    args << "--with-ar=#{ohos_bin}/llvm-ar"
    args << "--with-ranlib=#{ohos_bin}/llvm-ranlib"
    # 宿主端工具也需显式指定（--with-* 仅影响 $target 端）
    ENV["AR"] = "#{ohos_bin}/llvm-ar"
    ENV["RANLIB"] = "#{ohos_bin}/llvm-ranlib"
    ENV["NM"] = "#{ohos_bin}/llvm-nm"

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

    # 修正 AArch64 multilib 的 lib64 → lib ─────────────────────
    inreplace "gcc/config/aarch64/t-aarch64-linux",
              "lp64=../lib64", "lp64="

    # xgcc 对 AArch64 默认生成 .eh_frame,"aw"（可写），但 OHOS sysroot
    # 的 crtbegin.o 使用 .eh_frame,"a"（只读），clang 汇编器拒绝标志变更。
    # 将 EH_TABLES_CAN_BE_READ_ONLY 从 0 改为 1，让 xgcc 走 if 分支
    # 的 ASM_PREFERRED_EH_DATA_FORMAT 编码检测来决定 flags。
    inreplace "gcc/defaults.h",
              "#define EH_TABLES_CAN_BE_READ_ONLY 0",
              "#define EH_TABLES_CAN_BE_READ_ONLY 1"

    # ── 创建构建目录并执行三部曲 ────────────────────────────────
    mkdir "build" do
      system "../configure", *args

      # ISL 的 C++17 测试与 clang-15 不兼容（isl::id::try_user 不存在）。
      # 修改 GCC Makefile 中 ISL 的 configure 调用，传 CXX=false
      # 让 ISL 跳过 C++ 接口编译，GCC 只需 ISL 的 C 库。
      inreplace "Makefile",
        "--target=${target_alias} --disable-shared --with-gmp-builddir",
        "--target=${target_alias} --disable-shared CXX=false --with-gmp-builddir"

      # 目标库（由 xgcc 编译）需显式指定 OHOS sysroot 的架构目录
      # -isystem =/... 中 = 是 sysroot 占位符，xgcc 会自动替换
      #
      # OHOS 头文件含 __attribute__((__availability__(ohos, ...)))
      # 这是 clang 特有属性，xgcc 不认识。创建预包含头文件消除它。
      ohos_fix_header = buildpath/"ohos-gcc-fix.h"
      ohos_fix_header.atomic_write <<~C
        #define __availability__(...)
      C
      cppflags_target = "-include #{ohos_fix_header} -isystem =/usr/include/aarch64-linux-ohos"
      # -fPIC 导致 xgcc 即使在 -c 时也将 Scrt1.o 拉入链接，添加
      # -nostartfiles 防止 startup files 被包含。
      cflags_target = "--sysroot=#{sysroot} #{cppflags_target}"

      make_args = [
        "CPPFLAGS_FOR_TARGET=#{cppflags_target}",
        "CFLAGS_FOR_TARGET=#{cflags_target}",
        "CXXFLAGS_FOR_TARGET=#{cflags_target}",
        "LDFLAGS_FOR_TARGET=--sysroot=#{sysroot} -B#{sysroot}/usr/lib/aarch64-linux-ohos/ -L#{sysroot}/usr/lib/aarch64-linux-ohos -Wl,--code-sign",
      ]

      # Step 1 · 构建编译器本体（cc1 / cc1plus / xgcc，不安装）
      system "gmake", "-j#{ENV.make_jobs}", *make_args, "all-gcc"

      # Step 2 · 构建目标运行时库
      system "gmake", "-j#{ENV.make_jobs}", *make_args, "all-target-libgcc"
      system "gmake", "-j#{ENV.make_jobs}", *make_args, "all-target-libstdc++-v3"
      system "gmake", "-j#{ENV.make_jobs}", *make_args, "all-target-libatomic"

      # Step 3 · 仅安装目标运行时库（编译器二进制不入包）
      system "gmake", *make_args, "install-target-libgcc",
             "DESTDIR=#{Pathname.pwd}/../instdir"
      system "gmake", *make_args, "install-target-libstdc++-v3",
             "DESTDIR=#{Pathname.pwd}/../instdir"
      system "gmake", *make_args, "install-target-libatomic",
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
    clangxx = Formula["ohos-sdk"].opt_prefix/"native/llvm/bin/clang++"

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
