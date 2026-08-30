class Glibc < Formula
  desc "GNU C Library (glibc) 2.38 runtime for HarmonyOS, patched to load 2MiB-aligned ELF binaries"
  homepage "https://www.gnu.org/software/libc/"
  url "https://raw.githubusercontent.com/nknkol/harmonybrew-cask/main/bootstrap/glibc-2.38-harmonyos-arm64.tar.gz"
  sha256 "c268b80d19b50cfb5e9f9c397173ef654c4ecbada7e920bd34ee709f325332e2"
  license "LGPL-2.1-or-later"
  version "2.38"

  # keg_only: this is a glibc runtime used to run glibc-linked binaries
  # (e.g. Google Antigravity CLI) on the musl-based HarmonyOS system.  It must
  # not be linked into the system, which would conflict with the native musl.
  keg_only "glibc runtime for glibc-linked binaries; not meant to replace musl"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fglibc"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "90dcb9fc18e7b7b1649823cc563db59e715d4678dfe761e12af7a799085d8362"
  end

  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "llvm@21" => :build

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def llvm_objcopy
    Formula["llvm@21"].opt_bin/"llvm-objcopy"
  end

  def sign_elf!(path)
    unsigned = path.sub_ext("#{path.extname}.unsigned")
    signed = path.sub_ext("#{path.extname}.signed")

    rm_f unsigned
    rm_f signed
    chmod 0755, path

    if quiet_system llvm_objcopy, "--remove-section=.codesign", path, unsigned
      chmod 0755, unsigned
    else
      cp path, unsigned
    end

    system sign_tool, "sign", "-selfSign", "1", "-inFile", unsigned, "-outFile", signed
    chmod 0755, signed
    mv signed, path, force: true
  ensure
    rm_f unsigned if defined?(unsigned) && unsigned
    rm_f signed if defined?(signed) && signed
  end

  def install
    # The tarball contains the stripped, patched glibc runtime libraries:
    #   ld-linux-aarch64.so.1  libc.so.6  libm.so.6  libpthread.so.0
    #   libdl.so.2             libresolv.so.2  librt.so.1
    # All must be signed before they can be executed on HarmonyOS.
    lib.mkpath
    Dir[buildpath/"*.so*"].each do |so|
      next if File.symlink?(so)
      sign_elf! Pathname.new(so)
      lib.install so
    end
  end

  test do
    assert_predicate lib/"ld-linux-aarch64.so.1", :exist?
    assert_predicate lib/"libc.so.6", :exist?
  end
end
