class LlvmAT21 < Formula
  desc "LLVM 21.1.8 toolchain for HarmonyOS — clang, lld, compiler-rt"
  homepage "https://llvm.org"
  url "https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-21.1.8.zip"
  sha256 "2b2aae18bdba34ba8ee8249ad42ad3cb56f932f4142070c6eb920966f7c5905f"
  license "Apache-2.0"

  depends_on "nknkol/cask/binary-sign-tool" => :build
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
    patch_file = tap_root/"patches/llvm@21/0001-disable-emulated-tls.patch"
    cd buildpath do
      system "patch", "-f", "-p1", "-i", patch_file.to_s
    end
  end

  # ---------------------------------------------------------------
  # ELF 签名辅助
  # ---------------------------------------------------------------
  def elf_file?(path)
    return false unless path.file?
    path.open("rb") { |f| f.read(4) } == "\x7fELF".b
  rescue
    false
  end

  def sign_elf!(path)
    return unless elf_file?(path)

    unsigned = Pathname("#{path}.unsigned")
    signed   = Pathname("#{path}.signed")
    unsigned.unlink if unsigned.exist?
    signed.unlink   if signed.exist?

    sign_tool = Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
    objcopy = bin/"llvm-objcopy"

    path.chmod 0755

    # Remove existing .codesign section if present
    has_codesign = system objcopy, "--dump-section=.codesign=/dev/null", path.to_s,
                          err: File::NULL
    if has_codesign
      odie ".codesign removal failed on #{path}" unless
        system objcopy, "--remove-section=.codesign", path.to_s, unsigned.to_s
      unsigned.chmod 0755
    else
      FileUtils.cp path, unsigned
    end

    system sign_tool, "sign", "-inFile", unsigned.to_s,
           "-outFile", signed.to_s, "-selfSign", "1"
    signed.chmod 0755
    FileUtils.mv signed, path, force: true
  ensure
    unsigned&.unlink if unsigned&.exist?
    signed&.unlink   if signed&.exist?
  end

  def sign_tree!(root)
    return unless root.exist?
    root.find do |path|
      next if path.directory?
      sign_elf!(path)
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
      "-DCMAKE_EXE_LINKER_FLAGS=-lc++",
      "-DCMAKE_SHARED_LINKER_FLAGS=-lc++",
      "-DCMAKE_MODULE_LINKER_FLAGS=-lc++",
      "-DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-ohos",
      "-DDEFAULT_SYSROOT=#{ohos_sysroot}",
      "-DCLANG_DEFAULT_RTLIB=compiler-rt",
      "-DCLANG_DEFAULT_UNWINDLIB=libunwind",
      "-DCLANG_DEFAULT_CXX_STDLIB=libc++",
      "-DCLANG_DEFAULT_LINKER=lld",
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

    ohos_llvm_lib.glob("libunwind.*").each { |f| ln_s f, lib/f.basename }
    ohos_llvm_lib.glob("libc++*").each      { |f| ln_s f, lib/f.basename }

    # 后签名：鸿蒙 PC 要求所有 ELF 必须有效签名
    sign_tree!(lib)
    sign_tree!(bin)
  end

  test do
    (testpath/"hello.c").write <<~C
      #include <stdio.h>
      int main() { printf("hello\\n"); return 0; }
    C
    system bin/"clang", "hello.c", "-o", "hello"
    assert_equal "hello\n", shell_output("./hello")
  end
end
